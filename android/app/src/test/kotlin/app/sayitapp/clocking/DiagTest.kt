package app.sayitapp.clocking

import org.junit.Assert.assertEquals
import org.junit.Test

class DiagTest {

    @Test
    fun `numerele de telefon apar mascate in jurnal`() {
        assertEquals("***678", Diag.mask("+40712345678"))
        assertEquals("***", Diag.mask("12"))
        assertEquals("***", Diag.mask(null))
    }
}
