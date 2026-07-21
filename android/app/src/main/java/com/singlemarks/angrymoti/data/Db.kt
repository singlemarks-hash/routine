package com.singlemarks.angrymoti.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import kotlinx.coroutines.flow.Flow

@Dao
interface ReservationDao {
    @Query("SELECT * FROM reservations WHERE ownerUserID = :owner AND isActive = 1")
    fun activeFlow(owner: String): Flow<List<Reservation>>

    @Query("SELECT * FROM reservations WHERE ownerUserID = :owner AND isActive = 1")
    suspend fun active(owner: String): List<Reservation>

    @Query("SELECT * FROM reservations WHERE id = :id")
    suspend fun byId(id: String): Reservation?

    @Query("SELECT * FROM reservations WHERE ownerUserID = :owner AND groupId = :groupId")
    suspend fun byGroup(owner: String, groupId: String): List<Reservation>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(r: Reservation)

    @Delete
    suspend fun delete(r: Reservation)

    @Query("DELETE FROM reservations WHERE ownerUserID = :owner")
    suspend fun deleteAll(owner: String)
}

@Dao
interface SessionDao {
    @Query("SELECT * FROM sessions WHERE ownerUserID = :owner")
    fun allFlow(owner: String): Flow<List<FocusSession>>

    @Query("SELECT * FROM sessions WHERE ownerUserID = :owner")
    suspend fun all(owner: String): List<FocusSession>

    @Query("SELECT * FROM sessions")
    suspend fun allOwners(): List<FocusSession>

    @Query("SELECT * FROM sessions WHERE id = :id")
    suspend fun byId(id: String): FocusSession?

    @Query("SELECT COUNT(*) FROM sessions WHERE ownerUserID = :owner AND intensityRaw = 'spicy' AND outcomeRaw = 'completed'")
    suspend fun spicyCompletions(owner: String): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(s: FocusSession)

    @Delete
    suspend fun delete(s: FocusSession)

    @Query("DELETE FROM sessions WHERE ownerUserID = :owner")
    suspend fun deleteAll(owner: String)
}

@Dao
interface ScoreDao {
    @Query("SELECT * FROM score_events WHERE ownerUserID = :owner ORDER BY timestamp DESC")
    fun allFlow(owner: String): Flow<List<ScoreEvent>>

    @Query("SELECT COALESCE(SUM(points),0) FROM score_events WHERE ownerUserID = :owner")
    fun totalFlow(owner: String): Flow<Int>

    @Query("SELECT * FROM score_events WHERE sessionID = :sessionId")
    suspend fun bySession(sessionId: String): List<ScoreEvent>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(e: ScoreEvent)

    @Delete
    suspend fun delete(e: ScoreEvent)

    @Query("DELETE FROM score_events WHERE ownerUserID = :owner")
    suspend fun deleteAll(owner: String)
}

@Database(entities = [Reservation::class, FocusSession::class, ScoreEvent::class], version = 3, exportSchema = false)
abstract class AppDb : RoomDatabase() {
    abstract fun reservations(): ReservationDao
    abstract fun sessions(): SessionDao
    abstract fun scores(): ScoreDao

    companion object {
        /** v2: 노쇼 책임 기준 시각(accountableFrom) 추가 — 기존 데이터는 null(=createdAt 기준) */
        private val MIGRATION_1_2 = object : androidx.room.migration.Migration(1, 2) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE reservations ADD COLUMN accountableFrom INTEGER")
            }
        }

        /** v3: 그룹 챌린지 — 방 ID·종료일·강도 오버라이드 */
        private val MIGRATION_2_3 = object : androidx.room.migration.Migration(2, 3) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE reservations ADD COLUMN groupId TEXT")
                db.execSQL("ALTER TABLE reservations ADD COLUMN endAt INTEGER")
                db.execSQL("ALTER TABLE reservations ADD COLUMN intensityOverrideRaw TEXT")
            }
        }

        @Volatile private var instance: AppDb? = null
        fun get(context: Context): AppDb = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, AppDb::class.java, "angrymoti.db")
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3)
                .build().also { instance = it }
        }
    }
}
