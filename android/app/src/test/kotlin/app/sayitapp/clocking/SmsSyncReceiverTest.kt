package app.sayitapp.clocking

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SmsSyncReceiverTest {

    private lateinit var context: Context
    private val receiver = SmsSyncReceiver()
    private val partner = "+40722000111"
    private val code = "AAAA2222"
    private val msg = """CLK:P:{"i":"p1","e":"e1","t":1,"k":"i","u":1}"""
    private val sent = mutableListOf<Pair<String, String>>()

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString("flutter.sync_partner_phone", "0722 000 111")
            .putString("flutter.sync_secret", code)
            .commit()
        SmsSender.testSink = { phone, message -> sent.add(phone to message) }
    }

    @After
    fun tearDown() {
        SmsSender.testSink = null
    }

    private fun queue(): List<JSONObject> {
        val arr = JSONArray(SmsSyncReceiver.snapshot(context))
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    @Test
    fun `mesajul semnat de la partener intra in coada`() {
        receiver.handleSms(context, partner, SyncAuth.sign(code, msg))
        assertEquals(msg, queue().single().getString("msg"))
    }

    @Test
    fun `mesajul nesemnat de la partener e ignorat`() {
        receiver.handleSms(context, partner, msg)
        assertTrue(queue().isEmpty())
    }

    @Test
    fun `semnatura corecta de la alt numar e ignorata`() {
        receiver.handleSms(context, "+40799999999", SyncAuth.sign(code, msg))
        assertTrue(queue().isEmpty())
    }

    @Test
    fun `mesajul semnat cu alt cod e ignorat`() {
        receiver.handleSms(context, partner, SyncAuth.sign("BBBB3333", msg))
        assertTrue(queue().isEmpty())
    }

    @Test
    fun `mesajul modificat pe drum e ignorat`() {
        val signed = SyncAuth.sign(code, msg).replace("\"e1\"", "\"e2\"")
        receiver.handleSms(context, partner, signed)
        assertTrue(queue().isEmpty())
    }

    @Test
    fun `SMS-urile obisnuite nu sunt atinse`() {
        receiver.handleSms(context, partner, "Salut, vin mai târziu")
        assertTrue(queue().isEmpty())
    }

    @Test
    fun `trimiterea semneaza cu codul de imperechere`() {
        assertTrue(SmsSyncReceiver.sendSigned(context, msg))
        assertEquals("0722 000 111", sent.single().first)
        assertEquals(msg, SyncAuth.verify(code, sent.single().second))
    }

    @Test
    fun `fara cod de imperechere nu se trimite nimic`() {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .remove("flutter.sync_secret").commit()
        assertFalse(SmsSyncReceiver.isPaired(context))
        assertFalse(SmsSyncReceiver.sendSigned(context, msg))
        assertTrue(sent.isEmpty())
    }

    @Test
    fun `cererea de licenta fara licenta activa nu trimite nimic`() {
        receiver.handleSms(context, partner, SyncAuth.sign(code, SmsSyncReceiver.LICENSE_REQUEST_PREFIX))
        assertTrue(sent.isEmpty())
        assertTrue(queue().isEmpty())
    }
}
