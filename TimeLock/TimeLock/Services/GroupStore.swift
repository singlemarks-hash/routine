//
//  GroupStore.swift
//  TimeLock
//
//  그룹 챌린지 — 초대코드로 모인 계정들이 동일한 일정으로 대결하는 방.
//  서버 구조 (Firestore):
//    groups/{roomID}: 방 설정(이름·코드·강도·시간·요일·기간·상태·인원수)
//    groups/{roomID}/members/{uid}: 닉네임·그룹 점수·중도 포기 여부
//    users/{uid}.groupIDs: 내가 참여한 방 ID 배열
//  수명 주기(서버 함수 없이 클라이언트가 게으르게 처리):
//    scheduled → (시작 시각, 2명 이상) active → (종료 시각) 결과 열람 → 30일 후 삭제
//              → (시작 시각, 2명 미만) cancelled: 방장에게 안내 후 삭제
//  판정은 각자 기기에서 이뤄지고 점수만 서버에 합산된다 — 지인 신뢰 기반 대결.
//

import Foundation
import SwiftUI
import SwiftData
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

// MARK: - 모델

struct GroupRoom: Identifiable, Equatable, Hashable {
    // navigationDestination(item:)에서 요구. == 는 합성(전체 필드)을 유지하되 hash는 id만 —
    // "a == b ⇒ hash 동일" 규칙을 만족(동일 id)하면서 field 변경도 SwiftUI가 정상 감지한다.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: String
    var name: String
    var code: String
    var hostUID: String
    var intensityRaw: String
    var startMinute: Int
    var durationMinutes: Int
    var repeatWeekdays: [Int]
    var startDate: Date
    var endDate: Date
    var status: String          // scheduled | active | cancelled | disbanded
    var memberCount: Int

    var intensity: Intensity { Intensity(rawValue: intensityRaw) ?? .spicy }
    // startDate = 실제 시작 순간(시작일 자정 + 시작 시각). 생성 시 그 값으로 저장한다.
    var hasStarted: Bool { Date() >= startDate }
    /// 참여 가능 = 아직 scheduled이고 시작 11분 전이 지나지 않음 (10분 전 알람을 받을 수 있게)
    var joinOpen: Bool {
        status == "scheduled" &&
            Date() < startDate.addingTimeInterval(-Double(GroupPolicy.joinCutoffMinutes) * 60)
    }
    var isFinished: Bool { Date() >= endDate }
    @MainActor var isHostMine: Bool { hostUID == AccountStore.shared.currentUserID }
    /// 30일 보존 기간이 지나 서버에서 지워야 하는가
    var isExpired: Bool {
        Date() >= endDate.addingTimeInterval(TimeInterval(GroupPolicy.resultRetentionDays) * 86_400)
    }
}

struct GroupMember: Identifiable, Equatable {
    var id: String              // uid
    var nickname: String
    var score: Int
    var quit: Bool
    var joinedAt: Date
}

enum GroupError: LocalizedError {
    case backendUnavailable
    case roomNotFound
    case alreadyStarted
    case roomFull
    case nicknameTaken
    case alreadyJoined
    case scheduleConflict(String)
    case slotFull(used: Int, allowed: Int)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .backendUnavailable: return "그룹 기능은 네트워크 연결이 필요해요. 잠시 후 다시 시도해주세요."
        case .roomNotFound:       return "초대코드에 해당하는 방을 찾지 못했어요. 코드를 다시 확인해주세요."
        case .alreadyStarted:     return "이미 시작된 방에는 참여할 수 없어요."
        case .roomFull:           return "이 방은 정원(\(GroupPolicy.maxMembers)명)이 가득 찼어요."
        case .nicknameTaken:      return "이미 사용 중인 닉네임이에요. 다른 닉네임을 입력해주세요."
        case .alreadyJoined:      return "이미 참여 중인 방이에요."
        case .scheduleConflict(let name): return "기존 예약 '\(name)'과(와) 시간이 겹쳐요. 개인 예약을 옮기거나 삭제해야 참여할 수 있어요."
        case .slotFull(let used, let allowed):
            return "활동 슬롯이 가득 찼어요 (\(used)/\(allowed)). 그룹도 슬롯 1개를 차지해요 — 기존 활동을 정리하거나 연속 달성으로 슬롯을 늘려주세요."
        case .unknown(let message): return message
        }
    }
}

// MARK: - GroupStore

@MainActor
final class GroupStore: ObservableObject {
    static let shared = GroupStore()

    /// 내가 참여한 방 목록 (종료된 방 포함, 내가 '방 나가기' 하기 전까지)
    @Published private(set) var rooms: [GroupRoom] = []
    /// 방장에게 보여줄 안내: 시작 시각에 2명 미만이라 자동 삭제된 방 이름들
    @Published var cancelledNotices: [String] = []
    /// 참여자에게 보여줄 안내: 방장이 시작 전에 해체한 방
    @Published var disbandedNotices: [String] = []
    @Published private(set) var isRefreshing = false

    private var modelContext: ModelContext?
    private init() {}

    func bind(context: ModelContext) { modelContext = context }

    var backendActive: Bool { AccountStore.shared.backendActive }

    // MARK: 새로고침 — 목록 + 수명 주기 처리

    /// 내 방 목록을 다시 읽고, 시작/취소/종료/30일 정리를 게으르게 수행한다.
    func refresh() async {
        #if canImport(FirebaseFirestore)
        guard backendActive, AccountStore.shared.isSignedIn, !AccountStore.shared.isGuest else {
            rooms = []; return
        }
        guard !isRefreshing else { return }   // 동시 실행 방지 (안내 카드 중복 누적 차단)
        isRefreshing = true
        defer { isRefreshing = false }
        let db = Firestore.firestore()
        let uid = AccountStore.shared.currentUserID

        let ids = await myRoomIDs()
        var next: [GroupRoom] = []
        for id in ids {
            guard let snapshot = try? await db.collection("groups").document(id).getDocument() else { continue }
            guard snapshot.exists, var room = Self.room(from: snapshot) else {
                // 방 문서가 사라짐 = 해체·취소된 방을 다른 기기가 이미 지운 경우 (이름은 알 수 없어 일반 문구)
                disbandedNotices.append("참여했던 그룹방이 해체되었어요.")
                await removeMembershipRef(roomID: id)
                removeLocalReservation(roomID: id, purgeNoShows: true)
                continue
            }
            if room.status == "disbanded" {
                if !room.isHostMine { disbandedNotices.append("'\(room.name)' 방을 방장이 해체했어요.") }
                await removeMembershipRef(roomID: id)
                // 해체는 시작 전에만 가능 — 미리 만들어 둔 예약과 혹시 찍힌 노쇼까지 정리
                removeLocalReservation(roomID: id, purgeNoShows: true)
                // 서버 정리: 내 멤버 문서를 지우고, 마지막 참여자였다면 방 문서까지 삭제
                await cleanupDisbandedRoom(roomID: id, uid: uid)
                continue
            }
            // 시작 시각 도래 — 실제 멤버 문서 수가 최소 인원 이상이면 활성화, 미만이면 취소.
            // 판정 근거는 비정규화 카운터(memberCount)가 아니라 '실제 멤버 문서 수'다 —
            // 카운터 드리프트로 멤버가 충분한 방이 잘못 취소·삭제되던 문제(#04)를 차단.
            if room.status == "scheduled", room.hasStarted {
                let roomRef = db.collection("groups").document(id)
                let actualCount: Int
                if let snap = try? await roomRef.collection("members").getDocuments() {
                    actualCount = snap.documents.filter { ($0.data()["quit"] as? Bool) != true }.count
                } else {
                    actualCount = room.memberCount
                }
                let decided = actualCount >= GroupPolicy.minMembersToStart ? "active" : "cancelled"
                // compare-and-set — 아직 scheduled일 때만 바꾼다(여러 기기 동시 판정 방지) + 카운터 보정
                let finalStatus = (try? await db.runTransaction { transaction, errorPointer -> Any? in
                    let snap: DocumentSnapshot
                    do { snap = try transaction.getDocument(roomRef) }
                    catch let e as NSError { errorPointer?.pointee = e; return nil }
                    if (snap.data()?["status"] as? String) == "scheduled" {
                        transaction.updateData(["status": decided, "memberCount": actualCount],
                                               forDocument: roomRef)
                        return decided
                    }
                    return (snap.data()?["status"] as? String) ?? decided
                }) as? String ?? decided
                room.status = finalStatus
                room.memberCount = actualCount
            }
            if room.status == "cancelled" {
                if room.isHostMine {
                    cancelledNotices.append("'\(room.name)' — 참여자가 부족해 그룹방이 취소되었습니다.")
                }
                await removeMembershipRef(roomID: id)
                // mass-delete 금지 — 각자 자기 멤버 문서만 지우고, 마지막 참여자면 방 문서 삭제.
                // (한 기기가 전원 문서를 통째로 지우던 파괴적 경로 제거 — 오판이어도 폭파 안 됨)
                await cleanupDisbandedRoom(roomID: id, uid: uid)
                // 취소된 방은 예약 제거 + 그 예약에 잘못 찍힌 노쇼 기록까지 되돌린다
                removeLocalReservation(roomID: id, purgeNoShows: true)
                continue
            }
            // 30일 보존 기간 만료 → 서버에서 삭제
            if room.isExpired {
                await removeMembershipRef(roomID: id)
                try? await deleteRoomDocuments(roomID: id)
                removeLocalReservation(roomID: id)
                continue
            }
            // 그룹 예약은 참여 시점에 만들어지지만, 재설치·기기 변경 대비로 여기서도 보장한다.
            if room.status == "scheduled", !room.hasStarted {
                ensureLocalReservation(for: room)
            }
            if room.status == "active" {
                if room.isFinished {
                    removeLocalReservation(roomID: id)
                } else if await isMemberActive(roomID: id, uid: uid) {
                    ensureLocalReservation(for: room)
                }
            }
            next.append(room)
        }
        rooms = next.sorted { $0.startDate < $1.startDate }
        AppState.shared.rescheduleAlarmsForCurrentUser()
        #else
        rooms = []
        #endif
    }

    // MARK: 방 생성

    /// 방을 만들고 생성된 방(초대코드 포함)을 돌려준다.
    func createRoom(name: String, nickname: String, intensity: Intensity,
                    startMinute: Int, durationMinutes: Int, repeatWeekdays: [Int],
                    startDate: Date, endDate: Date) async throws -> GroupRoom {
        #if canImport(FirebaseFirestore)
        guard backendActive else { throw GroupError.backendUnavailable }
        let db = Firestore.firestore()
        let uid = AccountStore.shared.currentUserID

        // 초대코드 — 헷갈리는 문자(0/O/1/I) 제외, 중복 시 재발급
        var code = Self.randomCode()
        for _ in 0..<5 {
            let dup = try? await db.collection("groups")
                .whereField("code", isEqualTo: code).limit(to: 1).getDocuments()
            if dup?.documents.isEmpty != false { break }
            code = Self.randomCode()
        }

        let roomRef = db.collection("groups").document()
        let data: [String: Any] = [
            "name": name, "code": code, "hostUID": uid,
            "intensity": intensity.rawValue,
            "startMinute": startMinute, "durationMinutes": durationMinutes,
            "repeatWeekdays": repeatWeekdays,
            "startDate": Timestamp(date: startDate), "endDate": Timestamp(date: endDate),
            "status": "scheduled", "memberCount": 1,
            "takenNicknames": [nickname.lowercased()],   // 닉네임 유일성 판정 기반(#15) — 방장 닉네임을 미리 등록
            "createdAt": Timestamp(date: .now),
        ]
        do {
            try await roomRef.setData(data)
            try await roomRef.collection("members").document(uid).setData([
                "nickname": nickname, "score": 0, "quit": false,
                "joinedAt": Timestamp(date: .now),
                "timeZoneID": TimeZone.current.identifier,   // 타임존 저장 (다른 나라 멤버 표시·기간 계산 기반)
            ])
            try await db.collection("users").document(uid).setData(
                ["groupIDs": FieldValue.arrayUnion([roomRef.documentID])], merge: true)
        } catch {
            throw GroupError.unknown("방 생성에 실패했어요 — \(error.localizedDescription)")
        }
        let room = GroupRoom(id: roomRef.documentID, name: name, code: code, hostUID: uid,
                             intensityRaw: intensity.rawValue, startMinute: startMinute,
                             durationMinutes: durationMinutes, repeatWeekdays: repeatWeekdays,
                             startDate: startDate, endDate: endDate,
                             status: "scheduled", memberCount: 1)
        rooms.append(room)
        rooms.sort { $0.startDate < $1.startDate }
        // 예약을 지금 만들어 두어야 시작 시각 정각의 첫 알람이 울린다 (시작일 전엔 발생 없음)
        ensureLocalReservation(for: room)
        AppState.shared.rescheduleAlarmsForCurrentUser()
        return room
        #else
        throw GroupError.backendUnavailable
        #endif
    }

    // MARK: 참여

    /// 초대코드로 방을 조회한다 (참여 전 미리보기 + 일정 충돌 검사용).
    func lookup(code: String) async throws -> GroupRoom {
        #if canImport(FirebaseFirestore)
        guard backendActive else { throw GroupError.backendUnavailable }
        let normalized = code.uppercased().trimmingCharacters(in: .whitespaces)
        let snapshot = try? await Firestore.firestore().collection("groups")
            .whereField("code", isEqualTo: normalized).limit(to: 1).getDocuments()
        guard let doc = snapshot?.documents.first, let room = Self.room(from: doc) else {
            throw GroupError.roomNotFound
        }
        guard room.status == "scheduled" else { throw GroupError.alreadyStarted }
        guard Date() < room.startDate.addingTimeInterval(-Double(GroupPolicy.joinCutoffMinutes) * 60) else {
            throw GroupError.unknown("시작 \(GroupPolicy.joinCutoffMinutes)분 전이 지나 참여가 마감된 방이에요.")
        }
        return room
        #else
        throw GroupError.backendUnavailable
        #endif
    }

    /// 내 개인 예약과 방 일정이 겹치는지 검사. 겹치면 그 예약 이름을 담아 던진다.
    /// (다른 그룹 예약도 참여 시점에 미리 생성되므로 방끼리의 겹침도 여기서 함께 걸린다)
    func checkScheduleConflict(room: GroupRoom) throws {
        try checkScheduleConflict(startMinute: room.startMinute,
                                  durationMinutes: room.durationMinutes,
                                  repeatWeekdays: room.repeatWeekdays,
                                  startDate: room.startDate, endDate: room.endDate)
    }

    /// 그룹도 활동 슬롯 1개를 차지한다 — 슬롯이 가득 찼으면 생성·참여 모두 차단.
    /// (슬롯을 늘리려면 연속 달성이 필요하도록, 개인 예약과 동일한 규칙)
    func checkSlotAvailable() throws {
        guard let context = modelContext else { return }
        let owner = AccountStore.shared.currentUserID
        let reservations = (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.isActive && $0.ownerUserID == owner }))) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.ownerUserID == owner }))) ?? []
        let streak = SlotPolicy.currentStreak(sessions: sessions)
        if let allowed = SlotPolicy.allowedSlots(forStreak: streak,
                                                 isMember: SubscriptionManager.shared.isPro),
           reservations.count >= allowed {
            throw GroupError.slotFull(used: reservations.count, allowed: allowed)
        }
    }

    /// 방 생성 폼(방장)도 같은 검사를 쓴다 — 방장 본인의 기존 예약과 겹치면 생성 차단.
    func checkScheduleConflict(startMinute: Int, durationMinutes: Int, repeatWeekdays: [Int],
                               startDate: Date, endDate: Date) throws {
        guard let context = modelContext else { return }
        let owner = AccountStore.shared.currentUserID
        let mine = (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.isActive && $0.ownerUserID == owner }))) ?? []
        let calendar = Calendar.current
        for reservation in mine {
            guard reservation.overlaps(startMinute: startMinute, duration: durationMinutes)
            else { continue }
            if reservation.isRepeating {
                // 반복끼리는 요일이 하나라도 겹치면 충돌
                if !Set(reservation.repeatWeekdays).isDisjoint(with: repeatWeekdays) {
                    throw GroupError.scheduleConflict(reservation.name)
                }
            } else if let date = reservation.oneOffDate {
                // 일회성은 방 기간 안이고 요일이 겹치면 충돌
                let weekday = calendar.component(.weekday, from: date)
                if date >= calendar.startOfDay(for: startDate), date <= endDate,
                   repeatWeekdays.contains(weekday) {
                    throw GroupError.scheduleConflict(reservation.name)
                }
            }
        }
    }

    /// 방에 참여한다 (닉네임 선점·정원·중복 참여 검사 포함).
    func join(room: GroupRoom, nickname: String) async throws {
        #if canImport(FirebaseFirestore)
        guard backendActive else { throw GroupError.backendUnavailable }
        let db = Firestore.firestore()
        let uid = AccountStore.shared.currentUserID
        let roomRef = db.collection("groups").document(room.id)
        let memberRef = roomRef.collection("members").document(uid)
        let lowerNick = nickname.lowercased()

        // 정원 초과·닉네임 중복·중복 참여·마감을 '하나의 트랜잭션'으로 원자 확정(#15).
        // 읽고-쓰기가 분리돼 있으면 동시 참여 2건이 같은 빈자리·같은 닉네임을 함께 통과해
        // 정원 +1 초과나 동명이인이 생긴다 — 트랜잭션이 방 문서(memberCount·takenNicknames)를
        // 원자적으로 검사·갱신해 이 경합을 막는다. (트랜잭션은 컬렉션 질의가 불가하므로
        //  닉네임 유일성은 방 문서의 takenNicknames 배열로 판정한다.)
        var rejection: GroupError? = nil
        let result = try? await db.runTransaction { transaction, errorPointer -> Any? in
            let snap: DocumentSnapshot
            do { snap = try transaction.getDocument(roomRef) }
            catch let e as NSError { errorPointer?.pointee = e; return nil }
            let mine: DocumentSnapshot
            do { mine = try transaction.getDocument(memberRef) }
            catch let e as NSError { errorPointer?.pointee = e; return nil }
            guard snap.exists else { rejection = .roomNotFound; return nil }
            guard (snap.data()?["status"] as? String) == "scheduled" else { rejection = .alreadyStarted; return nil }
            let startTS = (snap.data()?["startDate"] as? Timestamp)?.dateValue() ?? .distantPast
            guard Date() < startTS.addingTimeInterval(-Double(GroupPolicy.joinCutoffMinutes) * 60) else {
                rejection = .unknown("시작 \(GroupPolicy.joinCutoffMinutes)분 전이 지나 참여가 마감됐어요. (10분 전 알람을 받을 수 있어야 참여할 수 있어요)")
                return nil
            }
            guard !mine.exists else { rejection = .alreadyJoined; return nil }
            let count = snap.data()?["memberCount"] as? Int ?? 0
            guard count < GroupPolicy.maxMembers else { rejection = .roomFull; return nil }
            let taken = (snap.data()?["takenNicknames"] as? [String]) ?? []
            guard !taken.contains(where: { $0.lowercased() == lowerNick }) else { rejection = .nicknameTaken; return nil }
            transaction.setData([
                "nickname": nickname, "score": 0, "quit": false,
                "joinedAt": Timestamp(date: .now),
                "timeZoneID": TimeZone.current.identifier,   // 타임존 저장 (다른 나라 멤버 표시·기간 계산 기반)
            ], forDocument: memberRef)
            transaction.updateData([
                "memberCount": count + 1,
                "takenNicknames": FieldValue.arrayUnion([lowerNick]),
            ], forDocument: roomRef)
            return true
        }
        if let rejection { throw rejection }
        guard result != nil else { throw GroupError.unknown("참여에 실패했어요 — 잠시 후 다시 시도해주세요.") }
        // 내 계정 문서의 그룹 목록 — 경합 무관(merge)이라 트랜잭션 밖
        try? await db.collection("users").document(uid).setData(
            ["groupIDs": FieldValue.arrayUnion([room.id])], merge: true)
        // 예약을 지금 만들어 두어야 시작 시각 정각의 첫 알람이 울린다 (시작일 전엔 발생 없음)
        ensureLocalReservation(for: room)
        AppState.shared.rescheduleAlarmsForCurrentUser()
        await refresh()
        #else
        throw GroupError.backendUnavailable
        #endif
    }

    // MARK: 멤버 & 랭킹

    func members(roomID: String) async -> [GroupMember] {
        #if canImport(FirebaseFirestore)
        guard backendActive else { return [] }
        let snapshot = try? await Firestore.firestore()
            .collection("groups").document(roomID).collection("members").getDocuments()
        return (snapshot?.documents ?? []).compactMap { doc in
            let data = doc.data()
            guard let nickname = data["nickname"] as? String else { return nil }
            return GroupMember(id: doc.documentID, nickname: nickname,
                               score: data["score"] as? Int ?? 0,
                               quit: data["quit"] as? Bool ?? false,
                               joinedAt: (data["joinedAt"] as? Timestamp)?.dateValue() ?? .now)
        }
        #else
        return []
        #endif
    }

    /// 점수 내림차순 + 공동 등수(1224 방식). 동점이면 같은 등수, 다음 등수는 인원만큼 건너뛴다.
    static func ranked(_ members: [GroupMember]) -> [(rank: Int, member: GroupMember)] {
        let sorted = members.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.joinedAt < $1.joinedAt
        }
        var result: [(Int, GroupMember)] = []
        var rank = 0
        var previousScore = Int.min
        for (index, member) in sorted.enumerated() {
            if member.score != previousScore {
                rank = index + 1
                previousScore = member.score
            }
            result.append((rank, member))
        }
        return result
    }

    // MARK: 그룹 점수 반영 (세션 판정 시 호출)

    /// 그룹 예약에서 나온 상벌점을 서버의 내 멤버 점수에 합산한다. 실패해도 로컬 원장이 원본.
    func reportScore(reservation: Reservation?, points: Int) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let roomID = reservation?.groupID, points != 0 else { return }
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty, uid != AccountStore.guestID else { return }
        Firestore.firestore().collection("groups").document(roomID)
            .collection("members").document(uid)
            .updateData(["score": FieldValue.increment(Int64(points))])
        #endif
    }

    // MARK: 탈퇴 · 해체 · 나가기

    /// 시작 전 자유 탈퇴 — 멤버 삭제 + 인원수 감소.
    func leaveBeforeStart(room: GroupRoom) async throws {
        #if canImport(FirebaseFirestore)
        guard backendActive else { throw GroupError.backendUnavailable }
        let db = Firestore.firestore()
        let uid = AccountStore.shared.currentUserID
        let roomRef = db.collection("groups").document(room.id)
        let memberRef = roomRef.collection("members").document(uid)
        // 내 닉네임을 takenNicknames에서 풀어 재사용 가능하게(#15) — 삭제 전에 읽어 둔다
        let myNick = (try? await memberRef.getDocument())?.data()?["nickname"] as? String
        try? await memberRef.delete()
        var updates: [String: Any] = ["memberCount": FieldValue.increment(Int64(-1))]
        if let myNick { updates["takenNicknames"] = FieldValue.arrayRemove([myNick.lowercased()]) }
        try? await roomRef.updateData(updates)
        await removeMembershipRef(roomID: room.id)
        removeLocalReservation(roomID: room.id)   // 미리 만들어 둔 예약 정리
        rooms.removeAll { $0.id == room.id }
        AppState.shared.rescheduleAlarmsForCurrentUser()
        #endif
    }

    /// 시작 후 중도 포기 — 벌점 -50 (그룹 점수 + 개인 누적), 남은 그룹 일정 삭제.
    func quitAfterStart(room: GroupRoom) async throws {
        #if canImport(FirebaseFirestore)
        guard backendActive else { throw GroupError.backendUnavailable }
        let db = Firestore.firestore()
        let uid = AccountStore.shared.currentUserID
        let memberRef = db.collection("groups").document(room.id)
            .collection("members").document(uid)
        try? await memberRef.updateData([
            "quit": true,
            "score": FieldValue.increment(Int64(ScoreRules.groupQuitPenalty)),
        ])
        // 개인 누적에도 동일 벌점 기록
        if let context = modelContext {
            let event = ScoreEvent(type: .groupQuit, points: ScoreRules.groupQuitPenalty,
                                   sessionID: nil, intensity: room.intensity,
                                   note: "그룹 '\(room.name)' 중도 포기",
                                   ownerUserID: uid)
            context.insert(event)
            try? context.save()
            AccountStore.shared.mirror(event: event)
        }
        removeLocalReservation(roomID: room.id)
        await removeMembershipRef(roomID: room.id)
        rooms.removeAll { $0.id == room.id }
        AppState.shared.rescheduleAlarmsForCurrentUser()
        #endif
    }

    /// 방장 전용, 시작 전 해체 — 참여자들은 다음 새로고침에서 안내를 받는다.
    func disband(room: GroupRoom) async throws {
        #if canImport(FirebaseFirestore)
        guard backendActive, room.isHostMine else { return }
        let db = Firestore.firestore()
        try? await db.collection("groups").document(room.id).updateData(["status": "disbanded"])
        await removeMembershipRef(roomID: room.id)
        // 방장 자신의 멤버 문서 정리 — 혼자였던 방이면 문서까지 즉시 삭제,
        // 참여자가 있으면 status로 해체를 알린 뒤 마지막 참여자가 문서를 지운다
        await cleanupDisbandedRoom(roomID: room.id, uid: AccountStore.shared.currentUserID)
        removeLocalReservation(roomID: room.id)   // 미리 만들어 둔 예약 정리
        rooms.removeAll { $0.id == room.id }
        AppState.shared.rescheduleAlarmsForCurrentUser()
        #endif
    }

    /// 종료된 방 '나가기' — 내 목록에서만 사라진다(다른 참여자의 결과는 유지).
    func hideFinishedRoom(room: GroupRoom) async {
        await removeMembershipRef(roomID: room.id)
        rooms.removeAll { $0.id == room.id }
    }

    // MARK: 내부

    /// 활성 방의 그룹 예약이 내 기기에 없으면 만든다.
    /// createdAt을 방 시작일로 두어, 앱을 늦게 열어도 시작일 이후의 노쇼가 전부 집계된다.
    private func ensureLocalReservation(for room: GroupRoom) {
        guard let context = modelContext else { return }
        let owner = AccountStore.shared.currentUserID
        let roomID = room.id
        let existing = (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.groupID == roomID && $0.ownerUserID == owner }))) ?? []
        guard existing.isEmpty else { return }

        let reservation = Reservation(name: room.name, tag: "그룹",
                                      startMinute: room.startMinute,
                                      durationMinutes: room.durationMinutes,
                                      repeatWeekdays: room.repeatWeekdays,
                                      // 일회성 그룹(요일 없음)은 방 시작일 하루만 발생
                                      oneOffDate: room.repeatWeekdays.isEmpty
                                          ? Calendar.current.startOfDay(for: room.startDate) : nil,
                                      ownerUserID: owner)
        reservation.groupID = room.id
        reservation.endDate = room.endDate
        reservation.intensityOverrideRaw = room.intensityRaw
        reservation.createdAt = room.startDate
        context.insert(reservation)
        try? context.save()
    }

    /// purgeNoShows: 방이 무산(취소)됐을 때 — 그 예약에 찍힌 노쇼 세션·벌점을 함께 되돌린다.
    private func removeLocalReservation(roomID: String, purgeNoShows: Bool = false) {
        guard let context = modelContext else { return }
        let owner = AccountStore.shared.currentUserID
        let list = (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.groupID == roomID && $0.ownerUserID == owner }))) ?? []
        guard !list.isEmpty else { return }
        for reservation in list {
            if purgeNoShows {
                let rid = reservation.id
                let noShowRaw = SessionOutcome.noShow.rawValue
                let sessions = (try? context.fetch(FetchDescriptor<FocusSession>(
                    predicate: #Predicate { $0.reservationID == rid && $0.outcomeRaw == noShowRaw }))) ?? []
                for session in sessions {
                    let sid = session.id
                    if let events = try? context.fetch(FetchDescriptor<ScoreEvent>(
                        predicate: #Predicate { $0.sessionID == sid })) {
                        events.forEach { context.delete($0) }
                    }
                    context.delete(session)
                }
            }
            // 폭파·취소·해체된 그룹 예약은 DB에서 완전 삭제 (소프트 삭제 아님) —
            // 방 문서가 사라졌으니 재생성되지 않는다.
            context.delete(reservation)
        }
        try? context.save()
    }

    private func myRoomIDs() async -> [String] {
        #if canImport(FirebaseFirestore)
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty else { return [] }
        let doc = try? await Firestore.firestore().collection("users").document(uid).getDocument()
        return doc?.data()?["groupIDs"] as? [String] ?? []
        #else
        return []
        #endif
    }

    private func removeMembershipRef(roomID: String) async {
        #if canImport(FirebaseFirestore)
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty else { return }
        try? await Firestore.firestore().collection("users").document(uid)
            .setData(["groupIDs": FieldValue.arrayRemove([roomID])], merge: true)
        #endif
    }

    /// 해체된 방의 서버 흔적 정리 — 내 멤버 문서 삭제, 남은 멤버가 없으면 방 문서까지 삭제.
    /// (해체는 status 변경만 하므로, 참여자들이 하나씩 빠져나가며 마지막이 문서를 지운다)
    private func cleanupDisbandedRoom(roomID: String, uid: String) async {
        #if canImport(FirebaseFirestore)
        let roomRef = Firestore.firestore().collection("groups").document(roomID)
        try? await roomRef.collection("members").document(uid).delete()
        if let remaining = try? await roomRef.collection("members").limit(to: 1).getDocuments(),
           remaining.documents.isEmpty {
            try? await roomRef.delete()
        }
        #endif
    }

    /// 방 문서 + 멤버 하위 컬렉션 삭제 (하위 컬렉션은 자동 삭제되지 않는다)
    private func deleteRoomDocuments(roomID: String) async throws {
        #if canImport(FirebaseFirestore)
        let roomRef = Firestore.firestore().collection("groups").document(roomID)
        if let members = try? await roomRef.collection("members").getDocuments() {
            for doc in members.documents { try? await doc.reference.delete() }
        }
        try? await roomRef.delete()
        #endif
    }

    #if canImport(FirebaseFirestore)
    private static func room(from doc: DocumentSnapshot) -> GroupRoom? {
        guard let data = doc.data(),
              let name = data["name"] as? String,
              let code = data["code"] as? String,
              let hostUID = data["hostUID"] as? String,
              let startMinute = data["startMinute"] as? Int,
              let durationMinutes = data["durationMinutes"] as? Int,
              let startTS = data["startDate"] as? Timestamp,
              let endTS = data["endDate"] as? Timestamp else { return nil }
        return GroupRoom(id: doc.documentID, name: name, code: code, hostUID: hostUID,
                         intensityRaw: data["intensity"] as? String ?? Intensity.spicy.rawValue,
                         startMinute: startMinute, durationMinutes: durationMinutes,
                         repeatWeekdays: data["repeatWeekdays"] as? [Int] ?? [],
                         startDate: startTS.dateValue(), endDate: endTS.dateValue(),
                         status: data["status"] as? String ?? "scheduled",
                         memberCount: data["memberCount"] as? Int ?? 0)
    }
    #endif

    /// 내가 아직 유효한(중도 포기 아님) 멤버인가
    private func isMemberActive(roomID: String, uid: String) async -> Bool {
        #if canImport(FirebaseFirestore)
        let doc = try? await Firestore.firestore().collection("groups").document(roomID)
            .collection("members").document(uid).getDocument()
        guard let data = doc?.data() else { return false }
        return (data["quit"] as? Bool ?? false) == false
        #else
        return false
        #endif
    }

    private static func randomCode() -> String {
        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // 0/O/1/I 제외
        return String((0..<GroupPolicy.codeLength).map { _ in charset.randomElement()! })
    }
}
