package app.sayitapp.clocking

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EntitlementTest {

    private val day = 24L * 60 * 60 * 1000
    private val start = 1_800_000_000_000L

    @Test
    fun `trial activ 30 de zile`() {
        assertTrue(Entitlement.isTrialActive(start, start + 29 * day))
        assertFalse(Entitlement.isTrialActive(start, start + 30 * day))
        assertEquals(30, Entitlement.trialDaysLeft(start, start))
        assertEquals(0, Entitlement.trialDaysLeft(start, start + 40 * day))
    }

    @Test
    fun `fara data de start trial-ul n-a inceput`() {
        assertTrue(Entitlement.isTrialActive(null, start))
        assertEquals(Entitlement.TRIAL_DAYS, Entitlement.trialDaysLeft(null, start))
    }

    @Test
    fun `data scrisa de Dart se citeste`() {
        assertNotNull(Entitlement.parseDartLocal("2026-10-22T09:15:30.123456"))
        assertNull(Entitlement.parseDartLocal("nu e data"))
        assertNull(Entitlement.parseDartLocal(null))
    }
}
