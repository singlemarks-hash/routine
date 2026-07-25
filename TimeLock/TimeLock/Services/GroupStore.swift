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
    /// 참여 마감(시작 10분 전)이 지났는데 최소 인원 미만 — 시작 시각에 삭제될 것이 이미 정해진 방.
    /// 서버 문서에는 없는 값이고, 새로고침이 실제 멤버 문서를 세어 채운다.
    var doomed: Bool = false

    var intensity: Intensity { Intensity(rawValue: intensityRaw) ?? .spicy }
    // startDate = 실제 시작 순간(시작일 자정 + 시작 시각). 생성 시 그 값으로 저장한다.
    var hasStarted: Bool { Date() >= startDate }
    /// 참여 가능 = 아직 scheduled이고 시작 11분 전이 지나지 않음 (10분 전 알람을 받을 수 있게)
    var joinOpen: Bool {
        status == "scheduled" &&
            Date() < startDate.addingTimeInterval(-Double(GroupPolicy.joinCutoffMinutes) * 60)
    }
    /// 마지막 활동이 실제로 끝나고 전원의 점수가 확정되는 시각.
    ///
    /// endDate는 '종료일의 끝(23:59:59)'이라 이걸 종료 기준으로 쓰면, 오전 11시에 10분짜리
    /// 활동을 끝낸 하루짜리 방이 그날 자정까지 '진행 중'으로 남는다. 실제 기준은
    /// `마지막 발생일 + 시작 시각 + 활동 길이 + 확정 유예(시작창 10분 + 재촬영창 10분)`이다.
    /// 마지막 발생일은 요일이 7개뿐이므로 종료일부터 거꾸로 최대 7일만 훑으면 반드시 나온다.
    var finishedAt: Date {
        let cal = Calendar.current
        let firstDay = cal.startOfDay(for: startDate)
        let lastDay = cal.startOfDay(for: endDate)
        let days = Set(repeatWeekdays)
        var occurrenceDay = lastDay
        if !days.isEmpty {
            var found: Date?
            for offset in 0..<8 {
                guard let d = cal.date(byAdding: .day, value: -offset, to: lastDay), d >= firstDay else { break }
                if days.contains(cal.component(.weekday, from: d)) { found = d; break }
            }
            // 못 찾으면(기간 안에 고른 요일이 없는 비정상 방) 가장 늦은 날 기준 — 일찍 끝난 것으로
            // 오판해 결과를 조기 삭제하는 쪽보다 늦게 끝나는 쪽이 안전하다.
            occurrenceDay = found ?? lastDay
        } else {
            occurrenceDay = firstDay   // 요일 정보가 없는 레거시 방 = 시작일 하루짜리
        }
        let base = cal.date(byAdding: .minute, value: startMinute, to: occurrenceDay) ?? startDate
        return base.addingTimeInterval(TimeInterval((durationMinutes + GroupPolicy.settleGraceMinutes) * 60))
    }
    var isFinished: Bool { Date() >= finishedAt }
    @MainActor var isHostMine: Bool { hostUID == AccountStore.shared.currentUserID }
    /// 결과 보존이 끝나 방이 자동 삭제되는 시각 (기준은 '종료일 자정'이 아니라 '실제 종료 시각')
    var deleteAt: Date {
        finishedAt.addingTimeInterval(TimeInterval(GroupPolicy.resultRetentionDays) * 86_400)
    }
    /// 보존 기간이 지나 서버에서 지워야 하는가
    var isExpired: Bool { Date() >= deleteAt }
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

        // 조회 실패(nil)면 이번 새로고침은 통째로 건너뛴다 — 빈 목록으로 오해해
        // 정상 그룹 예약을 지우거나 방 목록을 날리면 안 된다.
        guard let ids = await myRoomIDs() else { return }
        var next: [GroupRoom] = []
        for id in ids {
            guard let snapshot = try? await db.collection("groups").document(id).getDocument() else {
                // 조회 실패는 '방이 없다'가 아니다 — 아무것도 지우지 않고 이전 상태를 유지한다.
                // (여기서 next에 안 넣으면 진행 중인 방이 목록에서 통째로 사라져 보인다)
                if let previous = rooms.first(where: { $0.id == id }) { next.append(previous) }
                continue
            }
            guard snapshot.exists else {
                // 방 문서가 사라짐 — 이유는 알 수 없다. 시작 전이었다면 해체·취소된 방을
                // 다른 기기가 정리한 것이므로 미리 찍힌 기록까지 되돌린다. 반대로 이미 시작한
                // 방이면 보존 기간이 끝나 정리된 것이라, 그동안 정당하게 받은 벌점을 지우면
                // '한 달 잠수 후 앱을 열면 벌점이 사라지는' 회피 경로가 된다.
                // 이 기기가 한 번이라도 'active'로 본 방만 '진행했던 방'이다.
                // 본 적이 없으면 시작조차 못 하고 사라진 방이므로, 그 방에 찍힌 노쇼는
                // 전부 잘못된 기록이다(취소는 시작 10분 전에 이미 확정된 상태였다).
                let everRan = hasSeenRoomActive(id)
                // 멤버십 참조를 못 지우면 로컬도 건드리지 않는다 — 다음 새로고침에서 이 방이
                // 다시 '내 방'으로 잡혀 예약이 되살아나기 때문이다. 안내도 그때 한 번만 띄운다.
                guard await detachMembership(roomID: id) else { continue }
                disbandedNotices.append(everRan
                    ? "참여했던 그룹방의 결과 보존 기간이 끝나 정리되었어요."
                    : "참여했던 그룹방이 시작되지 못하고 정리되었어요. 관련 벌점은 취소했습니다.")
                removeLocalReservation(roomID: id, purgeNoShows: !everRan)
                forgetRoomActive(id)
                continue
            }
            guard var room = Self.room(from: snapshot) else {
                // 문서는 있는데 우리가 못 읽었다 — 다른 플랫폼·버전이 쓴 형식 차이이거나
                // 부분 쓰기일 수 있다. 살아 있는 방이므로 절대 지우지 않고 이번만 건너뛴다.
                if let previous = rooms.first(where: { $0.id == id }) { next.append(previous) }
                continue
            }
            if room.status == "disbanded" {
                guard await detachMembership(roomID: id) else { next.append(room); continue }
                if !room.isHostMine { disbandedNotices.append("'\(room.name)' 방을 방장이 해체했어요.") }
                // 해체는 시작 전에만 가능 — 미리 만들어 둔 예약과 혹시 찍힌 노쇼까지 정리
                removeLocalReservation(roomID: id, purgeNoShows: true)
                forgetRoomActive(id)
                // 서버 정리: 내 멤버 문서를 지우고, 마지막 참여자였다면 방 문서까지 삭제
                await cleanupDisbandedRoom(roomID: id, uid: uid)
                continue
            }
            // 참여 마감이 지났는데 최소 인원 미만 → 결과가 이미 확정된 방이다.
            // 더 들어올 사람이 없으므로 시작 시각에 반드시 취소된다. 그때까지 기다리지 말고
            // '삭제 예정'으로 표시하고, 진행되지 않을 활동의 알람을 미리 거둔다.
            // (판정 근거는 캐시된 카운터가 아니라 실제 멤버 문서 — 못 읽으면 아무것도 하지 않는다)
            // 이전 회차의 '삭제 예정' 판정을 승계한다. 방 객체는 매번 새로 파싱되므로
            // 승계하지 않으면 서버 조회가 한 번 실패한 회차에 판정이 풀리고, 아래에서
            // 지웠던 그룹 예약과 알람이 되살아난다(마감된 방인데 시작 시각에 울린다).
            if rooms.first(where: { $0.id == id })?.doomed == true { room.doomed = true }

            if room.status == "scheduled", !room.hasStarted, !room.joinOpen {
                // 캐시가 아니라 서버 값이어야 한다 — 오프라인 캐시로 '인원 미달'을 판정하면
                // 살아 있는 방의 예약과 알람을 지운다. 못 읽으면 승계된 판정을 그대로 쓴다.
                if let memberSnap = try? await db.collection("groups").document(id)
                    .collection("members").getDocuments(source: .server) {
                    room.memberCount = memberSnap.documents.filter { ($0.data()["quit"] as? Bool) != true }.count
                    room.doomed = room.memberCount < GroupPolicy.minMembersToStart
                }
                if room.doomed {
                    removeLocalReservation(roomID: id, purgeNoShows: true)
                    next.append(room)
                    continue
                }
            }
            // 시작 시각 도래 — 실제 멤버 문서 수가 최소 인원 이상이면 활성화, 미만이면 취소.
            // 판정 근거는 비정규화 카운터(memberCount)가 아니라 '실제 멤버 문서 수'다 —
            // 카운터 드리프트로 멤버가 충분한 방이 잘못 취소·삭제되던 문제(#04)를 차단.
            if room.status == "scheduled", room.hasStarted {
                let roomRef = db.collection("groups").document(id)
                // 멤버 문서를 못 읽었으면 판정 자체를 미룬다. 캐시된 카운터로 '취소'를 내리면
                // 정상 진행 중인 방이 폭파된다 — 네트워크가 돌아온 뒤 다시 판정하면 된다.
                guard let memberSnap = try? await roomRef.collection("members").getDocuments() else {
                    next.append(room); continue
                }
                let actualCount = memberSnap.documents.filter { ($0.data()["quit"] as? Bool) != true }.count
                let decided = actualCount >= GroupPolicy.minMembersToStart ? "active" : "cancelled"
                // compare-and-set — 아직 scheduled일 때만 바꾼다(여러 기기 동시 판정 방지) + 카운터 보정
                let committed = (try? await db.runTransaction { transaction, errorPointer -> Any? in
                    let snap: DocumentSnapshot
                    do { snap = try transaction.getDocument(roomRef) }
                    catch let e as NSError { errorPointer?.pointee = e; return nil }
                    if (snap.data()?["status"] as? String) == "scheduled" {
                        transaction.updateData(["status": decided, "memberCount": actualCount],
                                               forDocument: roomRef)
                        return decided
                    }
                    return (snap.data()?["status"] as? String) ?? decided
                }) as? String
                // 서버 기록에 실패했으면 판정을 적용하지 않는다. 실패한 판정을 확정으로 다루면
                // 서버는 아직 scheduled인데 이 기기만 '취소'로 믿고 허위 안내를 띄운 뒤
                // 내 멤버 문서를 지우고, 그 순간 혼자로 보였다면 남의 방 문서까지 삭제한다.
                // 방과 점수·예약을 그대로 둔 채 다음 새로고침에서 다시 시도한다.
                guard let finalStatus = committed else {
                    next.append(room); continue
                }
                room.status = finalStatus
                room.memberCount = actualCount
            }
            if room.status == "cancelled" {
                guard await detachMembership(roomID: id) else { next.append(room); continue }
                if room.isHostMine {
                    cancelledNotices.append("'\(room.name)' — 참여자가 부족해 그룹방이 취소되었습니다.")
                }
                // mass-delete 금지 — 각자 자기 멤버 문서만 지우고, 마지막 참여자면 방 문서 삭제.
                // (한 기기가 전원 문서를 통째로 지우던 파괴적 경로 제거 — 오판이어도 폭파 안 됨)
                await cleanupDisbandedRoom(roomID: id, uid: uid)
                // 취소된 방은 예약 제거 + 그 예약에 잘못 찍힌 노쇼 기록까지 되돌린다
                removeLocalReservation(roomID: id, purgeNoShows: true)
                forgetRoomActive(id)
                continue
            }
            // 30일 보존 기간 만료 → 서버에서 삭제
            if room.isExpired {
                guard await detachMembership(roomID: id) else { next.append(room); continue }
                try? await deleteRoomDocuments(roomID: id)
                removeLocalReservation(roomID: id)
                forgetRoomActive(id)
                continue
            }
            // 그룹 예약은 참여 시점에 만들어지지만, 재설치·기기 변경 대비로 여기서도 보장한다.
            if room.status == "scheduled", !room.hasStarted {
                ensureLocalReservation(for: room)
            }
            if room.status == "active" {
                markRoomActive(id)   // '실제로 진행된 방'으로 관측 — 문서가 사라진 뒤의 판정 근거
                // 끝난 방의 예약은 여기서 지우지 않는다. 지우면 마지막 날 노쇼가 집계되기 전에
                // 근거가 사라져 유실된다. 만료 정리(cleanupExpiredReservations)가 '마지막 활동이
                // 실제로 끝난 뒤'에 비활성화하므로 그 쪽에 맡긴다.
                if !room.isFinished, await isMemberActive(roomID: id, uid: uid) {
                    ensureLocalReservation(for: room)
                }
            }
            next.append(room)
        }
        // 고아 정리 기준은 '멤버십 목록(ids)'이지 '이번에 성공적으로 읽은 방(next)'이 아니다.
        // next를 쓰면 방 문서 조회가 한 번 실패(네트워크 등)한 것만으로 진행 중인 그룹의
        // 예약이 삭제되고, 다음 새로고침에서 새 UUID로 다시 만들어진다. 그러면 지난 기록과
        // ID가 달라져 이미 완료한 날까지 전부 노쇼로 재집계되는 대형 사고가 난다.
        // ids에 남아 있으면 아직 내 방이므로 보존하고, 명시적으로 정리된 방은 위 루프에서
        // 이미 removeLocalReservation으로 지워졌다.
        pruneOrphanGroupReservations(liveRoomIDs: Set(ids))
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

        // 초대코드 — 헷갈리는 문자(0/O/1/I) 제외, 중복 시 재발급.
        // 확인 조회가 '실패'한 것을 '중복 없음'으로 오해하면 안 된다 — 예전 조건은
        // 네트워크 오류로 nil이 와도 통과해, 확인 없이 코드를 확정했다.
        // 실패하면 같은 코드로 다시 확인하고, 끝내 확인하지 못하면 그대로 진행한다
        // (3,355만분의 1 위험보다 방을 못 만드는 쪽이 손해가 크다).
        var code = Self.randomCode()
        for _ in 0..<5 {
            guard let dup = try? await db.collection("groups")
                .whereField("code", isEqualTo: code).limit(to: 1).getDocuments() else {
                continue   // 확인 실패 — 코드를 바꾸지 않고 다시 확인한다
            }
            if dup.documents.isEmpty { break }
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
        // 끝난 활동은 슬롯을 차지하지 않는다 — 오늘 일정에 남아 있어도 자리는 이미 돌려준 상태다.
        let reservations = (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.isActive && $0.ownerUserID == owner })))?
            .filter { $0.hasRemainingOccurrence() } ?? []
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
        // 개인 예약 편집과 완전히 같은 규칙(ScheduleConflict)을 쓴다 —
        // 기간이 겹치고 그 안에서 같은 요일·시간대를 점유할 때만 충돌로 본다.
        // 예전에는 기간을 보지 않아 이미 끝난 개인 활동이 새 방 생성을 영영 막았고,
        // 자정을 넘기는 활동은 다음날 새벽 일정과 안 겹친다고 잘못 판정했다.
        let roomRange: (lo: Date, hi: Date?) = (calendar.startOfDay(for: startDate),
                                                calendar.startOfDay(for: endDate))
        // 레거시 일회성 방은 요일 배열이 비어 있다 — 그대로 두면 점유 구간이 없어져
        // 충돌 검사를 통째로 빠져나간다. 시작일의 요일로 채워 준다.
        let roomWeekdays = repeatWeekdays.isEmpty
            ? Set([calendar.component(.weekday, from: startDate)])
            : Set(repeatWeekdays)
        for reservation in mine {
            if ScheduleConflict.conflicts(
                aRange: roomRange, aWeekdays: roomWeekdays,
                aStart: startMinute, aDuration: durationMinutes,
                bRange: reservation.activeDayRange(calendar: calendar),
                bWeekdays: reservation.occupiedWeekdays(calendar: calendar),
                bStart: reservation.startMinute, bDuration: reservation.durationMinutes) {
                throw GroupError.scheduleConflict(reservation.name)
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
        // 화면 분기만 믿으면 안 된다 — 오프라인이라 status가 옛 'scheduled'로 남아 있으면
        // 이미 시작한 방을 벌점 없이 빠져나가는 회피 경로가 된다. 서버 문서로 확인한다.
        guard let snapshot = try? await roomRef.getDocument(source: .server),
              let live = Self.room(from: snapshot) else {
            throw GroupError.backendUnavailable
        }
        guard live.status == "scheduled", !live.hasStarted else { throw GroupError.alreadyStarted }
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
        // 내 계정 문서의 그룹 목록 — 경합 무관(merge)이라 트랜잭션 밖.
        // 여기서 실패를 삼키면 안 된다: 서버엔 멤버로 등록됐는데 내 그룹 목록에는 없어서,
        // 곧바로 도는 고아 정리가 방금 만든 예약을 지워 버린다(알람 없이 노쇼만 쌓임).
        do {
            try await db.collection("users").document(uid).setData(
                ["groupIDs": FieldValue.arrayUnion([room.id])], merge: true)
        } catch {
            throw GroupError.unknown("참여는 됐지만 목록 저장에 실패했어요 — 네트워크 확인 후 다시 시도해주세요.")
        }
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
        var list = (snapshot?.documents ?? []).compactMap { doc -> GroupMember? in
            let data = doc.data()
            guard let nickname = data["nickname"] as? String else { return nil }
            return GroupMember(id: doc.documentID, nickname: nickname,
                               score: data["score"] as? Int ?? 0,
                               quit: data["quit"] as? Bool ?? false,
                               joinedAt: (data["joinedAt"] as? Timestamp)?.dateValue() ?? .now)
        }
        // 방금 읽은 내 점수를 그대로 대조에 쓴다 — 확인하려고 같은 문서를 또 읽지 않는다.
        // 오래된 캐시 사본으로 판단하면 멀쩡한 점수를 망치므로 서버에서 온 응답일 때만 본다.
        guard snapshot?.metadata.isFromCache == false,
              let mine = list.firstIndex(where: { $0.id == AccountStore.shared.currentUserID }),
              let fixed = await repairMyScore(roomID: roomID, observed: list[mine].score)
        else { return list }
        list[mine].score = fixed   // 보정한 값이 이번 화면에 바로 보이도록
        return list
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
    /// 한 발생(활동 1회)에는 상벌점이 **한 번만** 반영된다.
    ///
    /// 그룹 점수는 더하기 방식이라, 기기가 둘이면 같은 발생을 각자 집계해 두 번 들어간다.
    /// (개인 원장은 결정적 ID로 이미 막혀 있어 그룹만 어긋났다)
    /// 그래서 발생마다 '반영함' 표식을 남기고, 표식이 있으면 그 요청은 버린다.
    /// 표식 확인과 점수 반영을 한 트랜잭션에 묶어 동시 실행에도 한 번만 들어간다.
    ///
    /// 표식에는 점수와 함께 '등급(rank)'을 적는다. 같은 발생에 노쇼와 완주가 함께 찍히는 일이
    /// 있는데(한 기기가 먼저 노쇼를 스윕하고, 다른 기기가 제시간 완주를 올린 경우) 이때
    /// 실제 결과인 완주가 이겨야 한다. 등급이 낮은 요청은 버리고, 같거나 높으면 차액만 보정한다.
    /// 호출 순서가 뒤바뀌어도 결과가 같다.
    func reportScore(reservation: Reservation?, points: Int, occurrenceKey: String, rank: Int) {
        guard let roomID = reservation?.groupID else { return }
        Task { try? await applyScore(roomID: roomID, points: points,
                                     occurrenceKey: occurrenceKey, rank: rank) }
    }

    /// 그룹 점수를 바꾸는 **유일한** 경로. 점수 변화는 반드시 표식을 남기고 일어난다.
    /// 표식이 곧 원장이므로, 어긋난 합계는 `repairMyScore(roomID:)`가 되돌릴 수 있다.
    func applyScore(roomID: String, points: Int, occurrenceKey: String, rank: Int) async throws {
        #if canImport(FirebaseFirestore)
        guard backendActive, points != 0 else { return }
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty, uid != AccountStore.guestID else { return }
        let db = Firestore.firestore()
        let memberRef = db.collection("groups").document(roomID).collection("members").document(uid)
        let markRef = memberRef.collection("scored").document(Self.markID(occurrenceKey))
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snap: DocumentSnapshot
            do { snap = try transaction.getDocument(markRef) }
            catch let e as NSError { errorPointer?.pointee = e; return nil }
            var delta = points
            if snap.exists {
                let oldRank = snap.data()?["rank"] as? Int ?? Self.scoreRankNormal
                let oldPoints = snap.data()?["points"] as? Int ?? 0
                guard rank >= oldRank else { return nil }          // 더 확실한 결과가 이미 있다
                guard rank > oldRank || points != oldPoints else { return nil }   // 같은 값 재요청
                delta = points - oldPoints                          // 차액만 보정
            }
            transaction.setData(["points": points, "rank": rank, "at": Timestamp(date: .now)],
                                forDocument: markRef)
            if delta != 0 {
                transaction.updateData(["score": FieldValue.increment(Int64(delta))],
                                       forDocument: memberRef)
            }
            return nil
        }
        #endif
    }

    /// 잘못 찍힌 노쇼를 지울 때 그 발생의 반영을 되돌린다.
    /// 표식에 적힌 값만큼만 빼고 표식을 지운다 — 반영된 적 없으면 아무것도 하지 않으므로
    /// 여러 기기가 동시에 되돌려도 한 번만 빠진다.
    /// 이미 완주 등급으로 덮인 표식은 건드리지 않는다(그건 정당한 점수다).
    func revokeScore(reservation: Reservation?, occurrenceKey: String) {
        #if canImport(FirebaseFirestore)
        guard backendActive, let roomID = reservation?.groupID else { return }
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty, uid != AccountStore.guestID else { return }
        let db = Firestore.firestore()
        let memberRef = db.collection("groups").document(roomID).collection("members").document(uid)
        let markRef = memberRef.collection("scored").document(Self.markID(occurrenceKey))
        Task {
            _ = try? await db.runTransaction { transaction, errorPointer -> Any? in
                let snap: DocumentSnapshot
                do { snap = try transaction.getDocument(markRef) }
                catch let e as NSError { errorPointer?.pointee = e; return nil }
                guard snap.exists, let points = snap.data()?["points"] as? Int else { return nil }
                let oldRank = snap.data()?["rank"] as? Int ?? Self.scoreRankNormal
                guard oldRank == Self.scoreRankNoShow else { return nil }
                transaction.deleteDocument(markRef)
                transaction.updateData(["score": FieldValue.increment(Int64(-points))],
                                       forDocument: memberRef)
                return nil
            }
        }
        #endif
    }

    /// 노쇼는 '아직 결과를 못 본' 추정치라 가장 낮은 등급이다.
    static let scoreRankNoShow = 0
    /// 실제로 화면을 통과한 결과(완주·이탈실패·긴급종료·일정취소)는 노쇼를 덮는다.
    static let scoreRankNormal = 1

    /// 중도 포기 벌점의 표식 키 — 방마다 한 번뿐이라 방 ID로 고정한다.
    /// 표식을 거치므로 두 번 눌러도(또는 두 기기에서 눌러도) 벌점은 한 번만 들어간다.
    static func quitOccurrenceKey(roomID: String) -> String { "groupquit|\(roomID)" }

    /// 서버의 내 점수를 표식 합계로 다시 맞춘다.
    ///
    /// 점수는 더하기로 쌓이는 값이라, 트랜잭션이 한 번이라도 실패하면(오프라인·권한 거부·
    /// 도중 강제 종료) 조용히 어긋난 채 영원히 그대로다. 표식이 원장이고 점수는 그 캐시이므로,
    /// 어긋났으면 원장에서 다시 만들 수 있다.
    ///
    /// 읽는 도중 다른 기기가 점수를 바꿨을 수 있으니, `observed`(합계를 세기 전에 읽은 점수)가
    /// 트랜잭션 안에서도 그대로일 때만 바꾼다. 달라졌으면 방금 들어온 정당한 점수이므로
    /// 이번 보정은 포기한다 — 다음 입장 때 다시 맞춘다.
    /// 맞춘 경우에만 새 점수를 돌려준다(고칠 게 없었으면 nil).
    func repairMyScore(roomID: String, observed: Int) async -> Int? {
        #if canImport(FirebaseFirestore)
        guard backendActive else { return nil }
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty, uid != AccountStore.guestID else { return nil }
        let db = Firestore.firestore()
        let memberRef = db.collection("groups").document(roomID).collection("members").document(uid)
        guard let marks = try? await memberRef.collection("scored")
            .getDocuments(source: .server) else { return nil }

        let total = marks.documents.reduce(0) { $0 + (($1.data()["points"] as? Int) ?? 0) }
        guard total != observed else { return nil }

        let done = (try? await db.runTransaction { transaction, errorPointer -> Any? in
            let snap: DocumentSnapshot
            do { snap = try transaction.getDocument(memberRef) }
            catch let e as NSError { errorPointer?.pointee = e; return nil }
            guard snap.exists, (snap.data()?["score"] as? Int) == observed else { return nil }
            transaction.updateData(["score": total], forDocument: memberRef)
            return true
        }) as? Bool
        return done == true ? total : nil
        #else
        return nil
        #endif
    }

    /// 발생 키를 문서 ID로 — 길이·문자 제한에 걸리지 않게 결정적 UUID로 줄인다.
    private static func markID(_ occurrenceKey: String) -> String {
        SessionEngine.deterministicUUID("groupscore|\(occurrenceKey)").uuidString.lowercased()
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
        // 실패를 삼키면 서버엔 멤버로 남은 채 로컬 예약만 사라져, 알람 없이 노쇼만 쌓인다.
        try await memberRef.delete()
        var updates: [String: Any] = ["memberCount": FieldValue.increment(Int64(-1))]
        if let myNick { updates["takenNicknames"] = FieldValue.arrayRemove([myNick.lowercased()]) }
        try? await roomRef.updateData(updates)
        try await removeMembershipRef(roomID: room.id)
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
        // 벌점을 먼저 넣고 포기 표시를 나중에 한다. 둘로 나뉜 쓰기라 중간에 끊길 수 있는데,
        // 순서가 반대면 '포기했는데 벌점은 없는' 상태로 남는다. 둘 다 표식/플래그라
        // 다시 눌러도 한 번만 들어가므로, 끊기면 재시도가 나머지를 채운다.
        // (벌점도 표식을 거쳐야 한다 — 건너뛰면 점수 재계산이 이 -50을 지워버린다)
        try await applyScore(roomID: room.id, points: ScoreRules.groupQuitPenalty,
                             occurrenceKey: Self.quitOccurrenceKey(roomID: room.id),
                             rank: Self.scoreRankNormal)
        // 실패를 삼키면 그룹엔 포기가 반영되지 않은 채 내 벌점만 기록된다.
        try await memberRef.updateData(["quit": true])
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
        try await removeMembershipRef(roomID: room.id)
        rooms.removeAll { $0.id == room.id }
        AppState.shared.rescheduleAlarmsForCurrentUser()
        #endif
    }

    /// 방장 전용, 시작 전 해체 — 참여자들은 다음 새로고침에서 안내를 받는다.
    func disband(room: GroupRoom) async throws {
        #if canImport(FirebaseFirestore)
        // 조용히 return하면 호출 측이 성공으로 착각해 화면을 닫는다 — 방은 그대로인데
        // '해체했다'고 오해하게 되므로 반드시 던진다.
        guard backendActive else { throw GroupError.backendUnavailable }
        guard room.isHostMine else { throw GroupError.unknown("방장만 해체할 수 있어요.") }
        let db = Firestore.firestore()
        // 시작 전에만 해체할 수 있다. 화면이 옛 상태를 들고 있으면 이미 진행 중인 방을
        // 해체로 덮어쓰게 되고, 그러면 전원의 refresh가 '해체된 방' 경로로 들어가
        // 그동안의 정당한 노쇼·벌점까지 클라우드 사본째 지워버린다. 되돌릴 수 없다.
        let roomRef = db.collection("groups").document(room.id)
        guard let snapshot = try? await roomRef.getDocument(source: .server),
              let live = Self.room(from: snapshot) else {
            throw GroupError.backendUnavailable
        }
        guard live.status == "scheduled", !live.hasStarted else { throw GroupError.alreadyStarted }
        // 상태 변경이 실패하면 나머지(로컬 정리)를 진행하면 안 된다 — 서버엔 방이 살아 있는데
        // 내 예약만 사라져 알람 없이 노쇼만 쌓인다.
        try await roomRef.updateData(["status": "disbanded"])
        try await removeMembershipRef(roomID: room.id)
        // 방장 자신의 멤버 문서 정리 — 혼자였던 방이면 문서까지 즉시 삭제,
        // 참여자가 있으면 status로 해체를 알린 뒤 마지막 참여자가 문서를 지운다
        await cleanupDisbandedRoom(roomID: room.id, uid: AccountStore.shared.currentUserID)
        removeLocalReservation(roomID: room.id)   // 미리 만들어 둔 예약 정리
        rooms.removeAll { $0.id == room.id }
        AppState.shared.rescheduleAlarmsForCurrentUser()
        #endif
    }

    /// 종료된 방 '나가기' — 내 목록에서만 사라진다(다른 참여자의 결과는 유지).
    /// 실패를 삼키면 로컬 예약만 지워진 채 방이 다음 새로고침에서 되살아난다 — 반드시 던진다.
    func hideFinishedRoom(room: GroupRoom) async throws {
        try await removeMembershipRef(roomID: room.id)
        // 끝난 방이라도 로컬 예약은 남아 일정·홈에 계속 뜬다 — 반드시 함께 정리한다.
        removeLocalReservation(roomID: room.id)
        rooms.removeAll { $0.id == room.id }
        AppState.shared.rescheduleAlarmsForCurrentUser()
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
        let stableID = Self.stableReservationID(roomID: roomID, owner: owner)
        if let current = existing.first {
            // 옛 버전이 무작위 ID로 만들어 둔 예약은 여기서 결정적 ID로 옮긴다.
            if current.id != stableID { migrateReservationID(current, to: stableID, context: context) }
            return
        }

        let reservation = Reservation(name: room.name, tag: "그룹",
                                      startMinute: room.startMinute,
                                      durationMinutes: room.durationMinutes,
                                      repeatWeekdays: room.repeatWeekdays,
                                      // 일회성 그룹(요일 없음)은 방 시작일 하루만 발생
                                      oneOffDate: room.repeatWeekdays.isEmpty
                                          ? Calendar.current.startOfDay(for: room.startDate) : nil,
                                      ownerUserID: owner)
        reservation.id = stableID
        reservation.groupID = room.id
        reservation.endDate = room.endDate
        reservation.intensityOverrideRaw = room.intensityRaw
        reservation.createdAt = room.startDate
        context.insert(reservation)
        try? context.save()
    }

    /// 이 기기가 'active'로 관측한 적 있는 방 번호들.
    ///
    /// 방 문서가 사라진 뒤에는 '진행했던 방'과 '시작조차 못 하고 취소된 방'을 구분할 수 없다.
    /// 시작 시각으로 추측하면 취소된 방도 시작 시각은 지났으므로 진행한 것으로 오판하고,
    /// 그 방에 잘못 찍힌 노쇼 벌점이 영구히 남는다.
    /// 그래서 추측하지 않고 **관측한 사실**을 기록해 둔다.
    private static let seenActiveKey = "group.seenActiveRoomIDs"

    private func markRoomActive(_ roomID: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.seenActiveKey) ?? [])
        guard ids.insert(roomID).inserted else { return }
        UserDefaults.standard.set(Array(ids), forKey: Self.seenActiveKey)
    }

    private func hasSeenRoomActive(_ roomID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.seenActiveKey) ?? []).contains(roomID)
    }

    private func forgetRoomActive(_ roomID: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.seenActiveKey) ?? [])
        guard ids.remove(roomID) != nil else { return }
        UserDefaults.standard.set(Array(ids), forKey: Self.seenActiveKey)
    }

    /// 그룹 예약의 신분증 — 무작위가 아니라 방 ID + 계정에서 계산한다.
    ///
    /// 그룹 예약은 클라우드에 미러링되지 않아 기기마다 새로 만들어진다. 그런데 완주·노쇼
    /// 기록(sessionSummaries)은 미러링되고 그 안에 예약 ID가 들어 있다. ID가 기기마다
    /// 다르면 클라우드에서 내려온 지난 기록이 이 예약에 연결되지 않고, 그룹 노쇼 스윕은
    /// 방 시작일부터 전 기간을 소급하므로 이미 완주한 날이 전부 노쇼로 재집계된다.
    /// (재설치·기기 추가 시 발생. 두 기기를 함께 쓰면 상시 발생)
    /// 방 ID에서 계산하면 어느 기기에서 만들어도 같은 값이라 기록이 그대로 이어진다.
    static func stableReservationID(roomID: String, owner: String) -> UUID {
        SessionEngine.deterministicUUID("groupres|\(roomID.lowercased())|\(owner.lowercased())")
    }

    /// 기존 설치본의 무작위 ID를 결정적 ID로 옮긴다. 그 예약에 딸린 세션의 연결도 함께
    /// 갱신하고 클라우드 사본에 다시 반영해, 모든 기기가 같은 ID로 수렴하게 한다.
    private func migrateReservationID(_ reservation: Reservation, to newID: UUID, context: ModelContext) {
        let oldID = reservation.id
        let sessions = (try? context.fetch(FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.reservationID == oldID }))) ?? []
        reservation.id = newID
        for session in sessions {
            session.reservationID = newID
            AccountStore.shared.mirrorSession(session)
        }
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
                        events.forEach {
                            // 클라우드 사본까지 지워야 다음 동기화에서 '세션 없는 유령 벌점'으로
                            // 되살아나지 않는다 (노쇼 복구 경로와 동일 규칙 — CLAUDE.md 불변식 #4)
                            AccountStore.shared.deleteMirroredEvent(id: $0.id)
                            context.delete($0)
                        }
                    }
                    AccountStore.shared.deleteMirroredSession(id: sid)
                    SessionStorage.deleteFiles(of: session)
                    context.delete(session)
                }
            }
            // 폭파·취소·해체된 그룹 예약은 DB에서 완전 삭제 (소프트 삭제 아님) —
            // 방 문서가 사라졌으니 재생성되지 않는다.
            context.delete(reservation)
        }
        try? context.save()
    }

    /// 내가 속한 방 ID 목록. nil = 조회 실패(네트워크 등) — '가입한 방이 하나도 없음'([])과
    /// 반드시 구분해야 한다. 실패를 []로 뭉개면 아래 고아 예약 스윕이 멀쩡한 그룹 예약을 전부 지운다.
    private func myRoomIDs() async -> [String]? {
        #if canImport(FirebaseFirestore)
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty else { return nil }
        // 이 결과로 로컬 그룹 활동을 지운다(pruneOrphanGroupReservations). 그래서 '못 읽었다'와
        // '가입한 방이 없다'를 반드시 구분해야 한다.
        //
        // getDocument()는 문서가 없어도 성공한다 — 빈 스냅샷이 돌아온다. 게다가 소스를 지정하지
        // 않으면 로컬 캐시로도 답한다. 그래서 새 기기·재설치·계정 전환처럼 캐시에 사용자 문서가
        // 없는 상태에서 '가입한 방 0개'로 읽혀, 멀쩡히 참여 중인 그룹 활동이 전부 지워졌다.
        // (그룹 탭도 일정 탭도 텅 비는데 슬롯만 물려 있던 원인)
        guard let doc = try? await Firestore.firestore()
            .collection("users").document(uid).getDocument(source: .server),
              doc.exists else { return nil }
        return doc.data()?["groupIDs"] as? [String] ?? []
        #else
        return nil
        #endif
    }

    /// 고아 그룹 예약 정리 — 서버 기준 내 방 목록에 없는 groupID의 로컬 예약을 제거한다.
    /// 나가기·해체·중도포기 중 어느 경로가 실패해 예약이 남더라도 다음 새로고침에서 자가 치유된다.
    /// (호출 측에서 '조회 성공'이 보장된 ID 목록만 넘길 것 — 실패 시 호출하면 안 된다)
    private func pruneOrphanGroupReservations(liveRoomIDs: Set<String>) {
        guard let context = modelContext else { return }
        let owner = AccountStore.shared.currentUserID
        let list = (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.groupID != nil && $0.ownerUserID == owner }))) ?? []
        var removed = false
        for reservation in list {
            guard let gid = reservation.groupID, !liveRoomIDs.contains(gid) else { continue }
            context.delete(reservation)
            removed = true
        }
        if removed { try? context.save() }
    }

    /// 실패를 삼키면 안 된다. 내 멤버 문서는 지워졌는데 groupIDs에 방이 남으면,
    /// 다음 새로고침이 그 방을 여전히 '내 방'으로 보고 예약을 다시 만들어 알람이 되살아난다.
    /// (나간 방에서 알람만 울리고, 멤버가 아니라 점수는 보고되지 않는 상태가 된다)
    /// 새로고침 루프용 — 사용자에게 던질 곳이 없으므로 성공 여부를 Bool로 돌려준다.
    /// false면 호출 측은 그 방의 로컬 정리를 건너뛰고 다음 새로고침에서 다시 시도해야 한다.
    private func detachMembership(roomID: String) async -> Bool {
        do { try await removeMembershipRef(roomID: roomID); return true }
        catch { return false }
    }

    private func removeMembershipRef(roomID: String) async throws {
        #if canImport(FirebaseFirestore)
        let uid = AccountStore.shared.currentUserID
        guard !uid.isEmpty else { return }
        try await Firestore.firestore().collection("users").document(uid)
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
