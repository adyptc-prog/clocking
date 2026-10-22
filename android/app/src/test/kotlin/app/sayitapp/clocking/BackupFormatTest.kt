package app.sayitapp.clocking

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BackupFormatTest {

    // Forma reală în care plugin-ul Dart shared_preferences scrie pe Android.
    private val prefs: Map<String, Any?> = mapOf(
        "flutter.shifts" to """{"u":0,"l":[]}""",
        "flutter.employees" to """[{"i":"e1","n":"Ana"}]""",
        "flutter.settings_updated" to 2L,
        "flutter.scan_sound" to true,
        "flutter.sync_partner_phone" to "0722000111",
        "flutter.trial_start_date" to "2026-09-01T10:00:00.000",
        "flutter.punches_2026-11" to """[{"i":"p1","e":"e1","t":1,"k":"i","u":1}]""",
        "flutter.some_float" to 1.5f,
        "flutter.legacy_set" to setOf("b", "a"),
        "flutter.license_expiry_warned_on" to "2026-9-24",
        "not_flutter_key" to "x",
    )
    private val identity = BackupFormat.Identity("organizator-1", """{"payload":{}}""")

    private fun roundTrip(): BackupFormat.Backup =
        BackupFormat.decode(BackupFormat.encode(prefs, identity, 1234L))

    private fun expectInvalid(content: String) {
        try {
            BackupFormat.decode(content)
            fail("trebuia respins")
        } catch (_: BackupFormat.InvalidBackupException) {
        }
    }

    @Test
    fun `datele si tipurile se pastreaza exact`() {
        val b = roundTrip()
        assertEquals(1234L, b.createdAt)
        assertEquals(prefs["flutter.employees"], b.prefs["flutter.employees"])
        assertEquals(2L, b.prefs["flutter.settings_updated"])
        assertTrue(b.prefs["flutter.settings_updated"] is Long)
        assertEquals(true, b.prefs["flutter.scan_sound"])
        assertEquals(1.5f, b.prefs["flutter.some_float"])
        assertEquals(setOf("a", "b"), b.prefs["flutter.legacy_set"])
        assertEquals(identity, b.identity)
    }

    @Test
    fun `cheile tranzitorii si straine nu intra in backup`() {
        val b = roundTrip()
        assertFalse(b.prefs.containsKey("flutter.license_expiry_warned_on"))
        assertFalse(b.prefs.containsKey("not_flutter_key"))
        assertTrue(b.prefs.containsKey("flutter.punches_2026-11"))
    }

    @Test
    fun `backup fara identitate`() {
        val content = BackupFormat.encode(prefs, BackupFormat.Identity(null, null), 1L)
        val b = BackupFormat.decode(content)
        assertNull(b.identity.businessId)
        assertNull(b.identity.licenseJson)
    }

    @Test
    fun `fisier modificat e respins prin checksum`() {
        val root = JSONObject(BackupFormat.encode(prefs, identity, 1L))
        root.put("data", root.getString("data").replace("Ana", "Ion"))
        expectInvalid(root.toString())
    }

    @Test
    fun `fisiere straine sau corupte sunt respinse`() {
        expectInvalid("nu e json")
        expectInvalid("SQLite format 3\u0000")
        expectInvalid("""{"app":"fidelio","formatVersion":1}""")
        expectInvalid("{}")
    }

    @Test
    fun `versiune de format mai noua e respinsa`() {
        val root = JSONObject(BackupFormat.encode(prefs, identity, 1L))
        root.put("formatVersion", BackupFormat.FORMAT_VERSION + 1)
        expectInvalid(root.toString())
    }

    @Test
    fun `restore inlocuieste datele si pastreaza partenerii actuali`() {
        val current = mapOf(
            "flutter.employees" to "[]",
            "flutter.punches_2020-01" to "[]", // lună care nu e în backup
            "flutter.sync_partner_phone" to "0733999888",
            "flutter.license_expiry_warned_on" to "2026-9-24",
        )
        val merged = BackupFormat.mergeForRestore(current, roundTrip().prefs, keepSyncPartners = true)
        assertEquals(prefs["flutter.employees"], merged["flutter.employees"])
        assertFalse(merged.containsKey("flutter.punches_2020-01"))
        assertEquals("0733999888", merged["flutter.sync_partner_phone"])
        assertEquals("2026-9-24", merged["flutter.license_expiry_warned_on"])
    }

    @Test
    fun `restore cu partenerii din backup`() {
        val current = mapOf("flutter.sync_partner_phone" to "0733999888")
        val merged = BackupFormat.mergeForRestore(current, roundTrip().prefs, keepSyncPartners = false)
        assertEquals("0722000111", merged["flutter.sync_partner_phone"])
    }

    @Test
    fun `partenerul actual ramane cand backup-ul nu are partener`() {
        val current = mapOf("flutter.sync_partner_phone" to "0744")
        val merged = BackupFormat.mergeForRestore(current, emptyMap(), keepSyncPartners = true)
        assertEquals("0744", merged["flutter.sync_partner_phone"])
        val dropped = BackupFormat.mergeForRestore(current, emptyMap(), keepSyncPartners = false)
        assertFalse(dropped.containsKey("flutter.sync_partner_phone"))
    }

    @Test
    fun `trial-ul nu se prelungeste prin restore`() {
        val older = "2026-01-01T00:00:00.000"
        val newer = "2026-09-01T10:00:00.000"
        val m1 = BackupFormat.mergeForRestore(
            mapOf("flutter.trial_start_date" to older),
            mapOf("flutter.trial_start_date" to newer), true)
        assertEquals(older, m1["flutter.trial_start_date"])
        val m2 = BackupFormat.mergeForRestore(
            mapOf("flutter.trial_start_date" to newer),
            mapOf("flutter.trial_start_date" to older), true)
        assertEquals(older, m2["flutter.trial_start_date"])
        val m3 = BackupFormat.mergeForRestore(
            mapOf("flutter.trial_start_date" to newer), emptyMap(), true)
        assertEquals(newer, m3["flutter.trial_start_date"])
    }

    @Test
    fun `identitatea se restaureaza fara a pierde o licenta activa`() {
        assertTrue(BackupFormat.shouldRestoreIdentity(currentLicenseActive = false, backupLicenseActive = false))
        assertTrue(BackupFormat.shouldRestoreIdentity(currentLicenseActive = false, backupLicenseActive = true))
        assertTrue(BackupFormat.shouldRestoreIdentity(currentLicenseActive = true, backupLicenseActive = true))
        assertFalse(BackupFormat.shouldRestoreIdentity(currentLicenseActive = true, backupLicenseActive = false))
    }

    @Test
    fun `retentie - se sterg doar backup-urile automate cele mai vechi`() {
        val names = listOf(
            "clocking_auto_20260101_000000.clkbackup",
            "clocking_auto_20260103_000000.clkbackup",
            "clocking_auto_20260102_000000.clkbackup",
            "clocking_20250101_120000.clkbackup", // manual — nu se atinge
            "clocking_auto_20250101_000000.txt",  // alt tip — nu se atinge
        )
        assertEquals(
            listOf("clocking_auto_20260101_000000.clkbackup"),
            BackupFormat.autoBackupsToDelete(names, keep = 2),
        )
        assertTrue(BackupFormat.autoBackupsToDelete(names, keep = 14).isEmpty())
    }

    @Test
    fun `codul de imperechere urmeaza regula partenerilor la restore`() {
        val current = mapOf("flutter.sync_secret" to "CURENT12")
        val backup = mapOf<String, Any?>("flutter.sync_secret" to "BACKUP12")
        assertEquals("CURENT12", BackupFormat.mergeForRestore(current, backup, keepSyncPartners = true)["flutter.sync_secret"])
        assertEquals("BACKUP12", BackupFormat.mergeForRestore(current, backup, keepSyncPartners = false)["flutter.sync_secret"])
    }
}
