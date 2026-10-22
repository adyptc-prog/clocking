package app.sayitapp.clocking

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.security.KeyFactory
import java.security.interfaces.RSAPublicKey
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** „Clocking” e un produs separat de celelalte aplicații Volt Academy. */
class AppIdentityTest {

    @Test
    fun `licenta are cheia proprie`() {
        // Fragmente din cheile publice ale Organizatorului și ale Rezervări Pensiune.
        assertFalse(LicenseStore.PUBLIC_KEY_B64.contains("6LMDi/tUuBHqLag6NHTw"))
        assertFalse(LicenseStore.PUBLIC_KEY_B64.contains("w8qB5prlJuqvSUDF2yjI"))
        val key = KeyFactory.getInstance("RSA").generatePublic(
            X509EncodedKeySpec(Base64.getDecoder().decode(LicenseStore.PUBLIC_KEY_B64))
        ) as RSAPublicKey
        assertEquals(2048, key.modulus.bitLength())
    }

    @Test
    fun `backup-urile si sincronizarea nu se confunda cu alte aplicatii`() {
        assertEquals("clocking", BackupFormat.APP_ID)
        assertEquals(".clkbackup", BackupFormat.EXTENSION)
        assertEquals("CLK:", SmsSyncReceiver.SYNC_PREFIX)
        assertEquals("CLK:S:", SyncAuth.SIGNED_PREFIX)
    }
}
