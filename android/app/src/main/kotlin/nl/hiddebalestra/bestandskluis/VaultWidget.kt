package nl.hiddebalestra.bestandskluis

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.Toast

/**
 * Widget op het startscherm: "Vergrendelen" (alle kluizen meteen op slot)
 * en "Kluis openen" (app openen en de laatst gebruikte kluis ontgrendelen,
 * met de vingerafdruk als die is ingesteld).
 */
class VaultWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_LOCK) {
            // Sleutels staan alleen in het geheugen van de draaiende app; draait
            // die niet, dan is alles al vergrendeld.
            MainActivity.lockAll("widget")
            Toast.makeText(context, "Kluizen vergrendeld", Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        const val ACTION_LOCK = "nl.hiddebalestra.bestandskluis.VERGRENDEL"
        const val ACTION_OPEN_VAULT = "nl.hiddebalestra.bestandskluis.OPEN_KLUIS"

        private fun views(context: Context): RemoteViews {
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val lock = PendingIntent.getBroadcast(
                context, 10,
                Intent(context, VaultWidget::class.java).setAction(ACTION_LOCK),
                flags
            )
            val open = PendingIntent.getActivity(
                context, 11,
                Intent(context, MainActivity::class.java)
                    .setAction(ACTION_OPEN_VAULT)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                flags
            )
            return RemoteViews(context.packageName, R.layout.widget_kluis).apply {
                setOnClickPendingIntent(R.id.widget_vergrendel, lock)
                setOnClickPendingIntent(R.id.widget_open, open)
            }
        }

        fun refresh(context: Context) {
            val m = AppWidgetManager.getInstance(context)
            val ids = m.getAppWidgetIds(ComponentName(context, VaultWidget::class.java))
            for (id in ids) m.updateAppWidget(id, views(context))
        }
    }
}
