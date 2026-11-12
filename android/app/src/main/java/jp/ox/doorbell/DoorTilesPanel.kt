// The dashboard's door tiles (docs/en/ui-guidelines.md, "Dashboard"): an adaptive grid of cards,
// each with the station's still, the door name, its last activity and a state chip (idle,
// ringing, in call, offline). A ringing tile is highlighted; a tap opens the live view. Split out
// of DashboardView; the still refresh rules are unchanged.
package jp.ox.doorbell

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.HttpURLConnection
import org.json.JSONObject

internal class DoorTilesPanel(
    private val activity: Activity,
    private val app: App,
    private val texts: Texts,
    private val ui: Handler,
    private val host: Host,
) {
    /** What the panel reads from the dashboard that owns it. */
    interface Host {
        val palette: Palette
        val roles: UiRoles
        val status: JSONObject?
        val config: JSONObject?
        val clock: ClusterClock
        fun doorLabel(door: String): String
        fun openNotice(door: String)
        fun showOfflineDoors()
        fun lastActivity(door: String): String
        fun paintRegion(view: TextView, region: String, backgroundRgb: Int, muted: Boolean)
    }

    private val palette: Palette get() = host.palette
    private val status: JSONObject? get() = host.status
    private val config: JSONObject? get() = host.config
    private val clock: ClusterClock get() = host.clock

    private val column = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val grid = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }

    /** What the dashboard mounts. */
    val scroll: ScrollView = ScrollView(activity).apply {
        // Deliberately not fillViewport: that re-measures the column to exactly the viewport
        // height, and a column taller than the viewport then crushes the tile captions to a few
        // pixels instead of scrolling.
        isFillViewport = false
        addView(column, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
    }

    /** The doors heading, rebuilt whenever the door set changes; it sits on the frame. */
    var heading: TextView? = null
        private set
    private var offlineDoorsButton: Button? = null

    /** A door tile's mutable parts, so a status poll updates rather than rebuilds. */
    private class DoorTile(
        val card: CardHandle,
        val body: LinearLayout,
        val still: ImageView,
        val chips: LinearLayout,
        val label: TextView,
        val activityLine: TextView,
        val noticeText: TextView,
    ) {
        val root: View get() = card.root
        var lastKey: String = "\u0000"
    }

    private val stills = HashMap<String, ImageView>()

    /** One tile view per door, built once and then only updated. */
    private val tiles = LinkedHashMap<String, DoorTile>()
    private val previewPriorityDoors = ArrayList<String>()
    private var tilesScrolled = false
    private var stillsLoading = false
    private var columns = 1

    /** The first door on screen, which the Monitor destination opens. */
    val firstDoor: String get() = tiles.keys.firstOrNull().orEmpty()
    val count: Int get() = tiles.size

    fun setColumns(value: Int) {
        val next = maxOf(1, value)
        if (next == columns) return
        columns = next
        layoutGrid()
        fitTilesToViewport()
    }

    /** Palette, roles or language changed: every tile restyles on the next update. */
    fun invalidate() {
        for (tile in tiles.values) tile.lastKey = "\u0000"
    }

    /**
     * Tiles are created once per door and then updated in place. Rebuilding them on every status
     * poll inflated a card, an image view and two labels per door several times a second, and
     * that was the hitch on the home page.
     */
    fun update() {
        val doors = tileDoorIds()
        var structureChanged = false
        // An empty door list on the very first build leaves tiles and doors both empty; the
        // childCount check makes sure the heading and the empty-state line still appear.
        if (tiles.keys.toList() != doors || column.childCount == 0) {
            structureChanged = true
            column.removeAllViews()
            grid.removeAllViews()
            tiles.clear()
            stills.clear()
            column.addView(
                ShellUi.sectionHeading(activity, palette,
                                       texts.t("settings.doors", R.string.settings_doors))
                    .also {
                        it.setPadding(ShellUi.dp(activity, UiTokens.SPACE_XS), it.paddingTop,
                                      ShellUi.dp(activity, UiTokens.SPACE_XS), it.paddingBottom)
                        heading = it
                    },
                ShellUi.matchWrap(),
            )
            offlineDoorsButton = PlatformUi.button(activity, ButtonKind.TONAL)
                .also { button ->
                    button.setOnClickListener { host.showOfflineDoors() }
                    PlatformUi.setButtonIcon(button, R.drawable.ic_tabler_video_off)
                    button.visibility = View.GONE
                    column.addView(button, ShellUi.matchWrap())
                }
            if (doors.isEmpty()) {
                column.addView(
                    ShellUi.label(activity, texts.t("dash.no_doors", R.string.dash_no_doors),
                                  TextRole.BODY, palette.muted),
                    ShellUi.matchWrap(),
                )
                return
            }
            for (door in doors) {
                val tile = createTile(door)
                tiles[door] = tile
                stills[door] = tile.still
            }
            column.addView(grid, ShellUi.matchWrap())
            layoutGrid()
        }
        renderOfflineDoorsButton()
        val nowMs = clock.cached().wallMs
        val calls = DashboardModel.callStates(status)
        for ((door, tile) in tiles) updateTile(
            door, tile, NoticeModel.resolve(status, config, door, nowMs), calls[door],
        )
        // A focusable tile pulls the scroll view to itself on first layout, which hid the
        // heading and clipped the first tile. Start at the top; the operator scrolls from there.
        if (!tilesScrolled) {
            tilesScrolled = true
            scroll.post { scroll.scrollTo(0, 0) }
        }
        if (structureChanged) fitTilesToViewport()
    }

    /**
     * A press or motion event promotes that camera to the first cell. All doors remain in the
     * grid, while only the cameras actually on screen are refreshed.
     */
    fun prioritizeDoor(door: String) {
        if (door.isEmpty()) return
        val promoted = tiles.remove(door) ?: return
        previewPriorityDoors.remove(door)
        previewPriorityDoors.add(0, door)
        while (previewPriorityDoors.size > 3) previewPriorityDoors.removeAt(3)
        val reordered = LinkedHashMap<String, DoorTile>()
        reordered[door] = promoted
        reordered.putAll(tiles)
        tiles.clear()
        tiles.putAll(reordered)
        layoutGrid()
        scroll.smoothScrollTo(0, 0)
        fitTilesToViewport()
        refreshStills()
    }

    /** Rows of [columns] cards; a short last row keeps its cells the same width as the others. */
    private fun layoutGrid() {
        if (tiles.isEmpty()) return
        grid.removeAllViews()
        val gap = ShellUi.dp(activity, UiTokens.SPACE_S)
        for (row in ScreenLayouts.rows(tiles.values.toList(), columns)) {
            val line = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                isBaselineAligned = false
            }
            for (index in 0 until columns) {
                val cell: View = row.getOrNull(index)?.root?.also { UiKit.detach(it) }
                    ?: View(activity)
                line.addView(cell, LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
                ).apply { if (index > 0) leftMargin = gap })
            }
            grid.addView(line, ShellUi.matchWrap().apply { topMargin = gap })
        }
    }

    /** The parts that never change for a door. Called once. */
    private fun createTile(door: String): DoorTile {
        val card = ShellUi.card(activity, palette)
        card.root.isFocusable = true
        card.root.isClickable = true
        card.root.setOnClickListener { IncomingActivity.launch(activity, door) }

        val still = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setBackgroundColor(ShellUi.opaque(palette.surfaceAlt))
            contentDescription = host.doorLabel(door)
        }
        // The still runs edge to edge at the top of the card and is the only part that may
        // shrink; the label and chips keep their height.
        card.content.addView(still, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ShellUi.dp(activity, 120),
        ))
        still.minimumHeight = ShellUi.dp(activity, 64)

        val body = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val pad = ShellUi.dp(activity, UiTokens.SPACE_L)
            setPadding(pad, ShellUi.dp(activity, UiTokens.SPACE_M), pad, ShellUi.dp(activity, UiTokens.SPACE_M))
        }
        card.content.addView(body, ShellUi.matchWrap())

        val label = ShellUi.label(activity, host.doorLabel(door), TextRole.SUBTITLE).apply {
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        body.addView(label, ShellUi.matchWrap())

        val activityLine = ShellUi.label(activity, "", TextRole.SUPPORTING).apply {
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            visibility = View.GONE
        }
        body.addView(activityLine, ShellUi.matchWrap())

        val chips = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(0, ShellUi.dp(activity, UiTokens.SPACE_S), 0, 0)
        }
        body.addView(chips, ShellUi.matchWrap())

        val noticeText = ShellUi.label(activity, "", TextRole.SUPPORTING).apply {
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
            visibility = View.GONE
        }
        body.addView(noticeText, ShellUi.matchWrap())
        return DoorTile(card, body, still, chips, label, activityLine, noticeText)
    }

    /** Everything a status poll can change, applied only when it actually changed. */
    private fun updateTile(door: String, tile: DoorTile, notice: Notice?, callState: String?) {
        val service = DoorStations.serviceOf(status, config, door)
        val state = DashboardModel.tileState(service, callState)
        val roles = host.roles
        val noticeKey = notice?.text ?: ""
        val lastActivity = host.lastActivity(door)
        val label = host.doorLabel(door)
        val key = listOf(noticeKey, state.name, lastActivity, label, texts.lang,
                         palette.dark.toString(), roles.accent.toString()).joinToString("\u0001")
        if (tile.lastKey == key) return
        tile.lastKey = key

        tile.card.setHighlighted(DashboardModel.highlighted(state))
        tile.label.text = label
        // A tile label sits on the card surface, a different background from the ground.
        host.paintRegion(tile.label, "tile_label", palette.surface, false)
        tile.activityLine.text = lastActivity
        tile.activityLine.visibility = if (lastActivity.isEmpty()) View.GONE else View.VISIBLE
        host.paintRegion(tile.activityLine, "notice", palette.surface, true)

        tile.chips.removeAllViews()
        val stateText = stateLabel(state)
        val role = DashboardModel.chipRole(state)
        tile.chips.addView(
            if (role == ActionRole.SECONDARY) PlatformUi.chip(activity, stateText, ChipKind.STATUS)
            else PlatformUi.chip(activity, stateText, ChipKind.STATUS,
                                 fillRgb = roles.fill(role), inkRgb = roles.ink(role)),
        )
        if (notice != null) {
            // A chip while an announcement is showing (§5.2); tapping it opens the editor.
            val chip = PlatformUi.chip(
                activity, texts.t("notice.active", R.string.notice_active), ChipKind.ACTION,
                R.drawable.ic_tabler_note, palette.noticeBg, palette.noticeInk,
            )
            chip.setOnClickListener { host.openNotice(door) }
            tile.chips.addView(chip, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { leftMargin = ShellUi.dp(activity, UiTokens.SPACE_S) })
        }
        tile.noticeText.text = noticeKey
        tile.noticeText.visibility = if (notice != null) View.VISIBLE else View.GONE
        host.paintRegion(tile.noticeText, "notice", palette.surface, true)
        tile.root.contentDescription = listOf(label, stateText, lastActivity)
            .filter { it.isNotEmpty() }.joinToString(", ")
    }

    private fun stateLabel(state: TileState): String = when (state) {
        TileState.IDLE -> texts.t("dash.state_idle", R.string.dash_state_idle)
        TileState.RINGING -> texts.t("dash.state_ringing", R.string.dash_state_ringing)
        TileState.IN_CALL -> texts.t("dash.state_in_call", R.string.dash_state_in_call)
        TileState.OFFLINE -> texts.t("dash.tile_offline", R.string.dash_tile_offline)
        TileState.NO_STATION -> texts.t("dash.tile_no_station", R.string.dash_tile_no_station)
    }

    private fun applyStillHeight(heightPx: Int) {
        for (tile in tiles.values) {
            val params = tile.still.layoutParams ?: continue
            if (params.height == heightPx) continue
            params.height = heightPx
            tile.still.layoutParams = params
        }
    }

    /**
     * Size the preview so a whole row of tiles fits in the viewport. The still is the only part
     * that may give up height, so it is measured against the real viewport instead of guessed per
     * orientation. More rows than fit still scroll, but every row is whole.
     */
    fun fitTilesToViewport() {
        val tile = tiles.values.firstOrNull() ?: return
        scroll.post {
            val viewport = scroll.height
            if (viewport <= 0 || tile.still.layoutParams == null) return@post
            val card = tile.root
            // Everything in the card except the still: the padded text block under it.
            val others = tile.body.height
            val heading = if (column.childCount > 0) column.getChildAt(0).height else 0
            val rows = DashboardModel.tileRows(tiles.size, columns)
            val cellWidth = maxOf(1, card.width.takeIf { it > 0 } ?: (scroll.width / columns))
            val cap = when {
                rows <= 1 -> 280
                rows <= 2 -> 180
                else -> 112
            }
            val maxHeight = minOf(cellWidth * 9 / 16, ShellUi.dp(activity, cap))
            applyStillHeight(VisitorLayout.tileStillHeightPx(
                viewportPx = viewport,
                headingPx = heading,
                otherRowsPx = others,
                gapPx = ShellUi.dp(activity, 16),
                tileCount = rows,
                minPx = ShellUi.dp(activity, 56),
                maxPx = maxOf(ShellUi.dp(activity, 56), maxHeight),
            ))
        }
    }

    /**
     * The doors that get a tile. A station that reports caps.camera false is left out -- there
     * is nothing to show and nothing to watch. The door stays reachable everywhere else.
     */
    private fun tileDoorIds(): List<String> {
        val available = DoorStations.allDoorIds(status, config)
            .filter { DoorStations.tileVisible(status, config, it) }
        val promoted = previewPriorityDoors.filter { available.contains(it) }
        return promoted + available.filterNot { promoted.contains(it) }
    }

    private fun renderOfflineDoorsButton() {
        val button = offlineDoorsButton ?: return
        val offline = DoorStations.offlineDoors(status, config)
        button.visibility = if (offline.isEmpty()) View.GONE else View.VISIBLE
        if (offline.isNotEmpty()) {
            button.text = "${texts.t("dashboard.offline_doors", R.string.dashboard_offline_doors)}" +
                " · ${offline.size}"
        }
    }

    /**
     * Refresh every tile's picture, at the per-device preview rate ([PreviewRate]); a failure
     * simply leaves the previous frame.
     *
     * The peer is resolved per door on each pass rather than captured with the tile, so a station
     * that joins after its tile was built starts showing a picture on the next tick instead of
     * staying blank until the door set changes. Each door is attempted independently: one station
     * that is down must not stop the loop before it reaches the others, which is why the body is
     * wrapped rather than relying on fetchStill alone to swallow everything.
     */
    fun refreshStills() {
        if (stills.isEmpty() || stillsLoading) return
        // Snapshot decoding and network I/O scale with what the resident can see, not with fleet
        // size. Safe mode admits one; the normal lane admits at most three per refresh cycle.
        val budget = if (app.safeMode) 1 else 3
        val visible = Rect()
        val targets = tiles.entries.filter { (_, tile) ->
            tile.root.getLocalVisibleRect(visible) && visible.height() > 0
        }.map { it.key }.take(budget).ifEmpty { tiles.keys.take(budget) }
        if (targets.isEmpty()) return
        stillsLoading = true
        val snapshot = status
        val settings = config
        Thread({
            try {
                for (door in targets) try {
                    // Only a station the mesh says is alive. This used to accept any peer bound
                    // to the door, because served_by and peers[].status could disagree and a
                    // serving station was being reported offline; core resolves both from one
                    // liveness source now, so the workaround is gone.
                    val peer = DoorStations.alivePeer(snapshot, settings, door)
                    if (peer == null) {
                        // Say which peers were considered and how each resolved: "no station" on
                        // its own cannot tell a door-id mismatch from a station that is down.
                        logStill(door, "no alive station; " + DoorStations.why(snapshot, settings, door))
                        continue
                    }
                    val url = DoorStations.stillUrl(peer)
                    if (url.isEmpty()) {
                        logStill(
                            door,
                            "station ${peer.optString("id")} (status " +
                                "${peer.optString("status")}) advertises no snapshot or stream",
                        )
                        continue
                    }
                    val bitmap = fetchStill(door, url) ?: continue
                    ui.post { stills[door]?.setImageBitmap(bitmap) }
                } catch (error: Exception) {
                    logStill(door, "failed: ${error.javaClass.simpleName}: ${error.message}")
                }
            } finally {
                ui.post { stillsLoading = false }
            }
        }, "doorbell-tiles").apply { isDaemon = true }.start()
    }

    /**
     * One still. Every outcome is logged with the URL, the HTTP status, the byte count and
     * whether the decode produced a bitmap.
     *
     * This used to swallow the exception silently, which is how a blocked request looked exactly
     * like a station with no camera: an empty tile and nothing at all in logcat.
     */
    private fun fetchStill(door: String, url: String): Bitmap? {
        var connection: HttpURLConnection? = null
        return try {
            connection = LocalMedia.open(url)
            connection.connectTimeout = 2000
            connection.readTimeout = 3000
            connection.useCaches = false
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) {
                logStill(door, "$url -> HTTP $code")
                return null
            }
            val bytes = BoundedBitmapDecoder.readLimited(connection.inputStream, 2 * 1024 * 1024)
            if (bytes == null) {
                logStill(door, "$url -> HTTP $code, body empty or over the 2 MB cap")
                return null
            }
            val bitmap = BoundedBitmapDecoder.decode(bytes, 640, 480)
            logStill(
                door,
                "$url -> HTTP $code, ${bytes.size} bytes, " +
                    if (bitmap == null) "decode failed"
                    else "decoded ${bitmap.width}x${bitmap.height}",
            )
            bitmap
        } catch (error: Exception) {
            // A cleartext-policy refusal arrives here as an IOException naming the peer address.
            logStill(door, "$url -> ${error.javaClass.simpleName}: ${error.message}")
            null
        } finally {
            try { connection?.disconnect() } catch (e: Exception) { ShellLog.ignored("DoorTilesPanel", e) }
        }
    }

    private fun logStill(door: String, message: String) {
        android.util.Log.i("doorbell-still", "[$door] $message")
    }
}
