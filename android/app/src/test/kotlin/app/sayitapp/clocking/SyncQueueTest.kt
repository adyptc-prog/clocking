package app.sayitapp.clocking

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SyncQueueTest {

    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
    }

    private fun ids(json: String): List<String> {
        val arr = JSONArray(json)
        return (0 until arr.length()).map { arr.getJSONObject(it).getString("id") }
    }

    private fun msgs(json: String): List<String> {
        val arr = JSONArray(json)
        return (0 until arr.length()).map { arr.getJSONObject(it).getString("msg") }
    }

    @Test
    fun `mesajul sosit in timpul procesarii nu se pierde`() {
        SmsSyncReceiver.enqueue(context, """CLK:E:{"i":"a"}""")
        val read = SmsSyncReceiver.snapshot(context)

        // Un SMS nou sosește cât timp Flutter încă procesează ce a citit.
        SmsSyncReceiver.enqueue(context, """CLK:P:{"i":"b"}""")
        SmsSyncReceiver.acknowledge(context, ids(read))

        assertEquals(listOf("""CLK:P:{"i":"b"}"""), msgs(SmsSyncReceiver.snapshot(context)))
    }

    @Test
    fun `fiecare intrare are un id unic`() {
        SmsSyncReceiver.enqueue(context, "CLK:Z:")
        SmsSyncReceiver.enqueue(context, "CLK:Z:")
        assertEquals(2, ids(SmsSyncReceiver.snapshot(context)).toSet().size)
    }

    @Test
    fun `coada corupta nu blocheaza mesajele noi`() {
        context.getSharedPreferences(SmsSyncReceiver.PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putString(SmsSyncReceiver.QUEUE_KEY, "{corupt")
            .commit()
        SmsSyncReceiver.enqueue(context, "CLK:Z:")
        assertEquals(listOf("CLK:Z:"), msgs(SmsSyncReceiver.snapshot(context)))
    }

    @Test
    fun `confirmarea unor id-uri necunoscute nu sterge nimic`() {
        SmsSyncReceiver.enqueue(context, "CLK:Z:")
        SmsSyncReceiver.acknowledge(context, listOf("necunoscut"))
        assertTrue(msgs(SmsSyncReceiver.snapshot(context)).contains("CLK:Z:"))
    }
}
