extends Node3D
## ONE MORE DRINK - endless driving game about alcohol impairment (Godot 4.1+)
## Attach this script to a Node3D root, save the scene and press F5.
## Controls: A / Left = change lane left, D / Right = change lane right
##           Enter / Space / R = start / restart
##
## Arcade-style logic: no physics engine, collisions are simple box overlap tests.

enum State { MENU, PLAYING, GAME_OVER }

# --- Road / player ------------------------------------------------------------
const LANE_WIDTH := 3.5
const ROAD_HALF := 5.25            # road is 10.5 m wide, 3 lanes
const OFFROAD_LIMIT := 5.3         # |x| beyond this = left the road
const PLAYER_HALF := Vector2(0.9, 2.0)   # half width (x), half length (z)
const LATERAL_SPEED := 11.0        # m/s when changing lanes

# --- Speed / progression ------------------------------------------------------
const START_SPEED := 18.0          # m/s
const MAX_SPEED := 60.0
const ACCEL := 0.4                 # m/s gained per second
const SEGMENT_LENGTH := 700.0      # metres per route segment (+50 pts, +1 alcohol level)

# --- Traffic ------------------------------------------------------------------
const SPAWN_AHEAD := 190.0
const MIN_GAP := 22.0
const PED_SPEED := 2.4

# --- World streaming ----------------------------------------------------------
const CHUNK_LEN := 100.0
const NUM_CHUNKS := 6
const BASE_FOV := 68.0

# --- Alcohol tuning, indexed by level 0..3 (values are interpolated smoothly) ---
const DELAY := [0.0, 0.18, 0.28, 0.55]      # seconds of input delay
const LANE_ERR := [0.0, 0.0, 0.7, 1.3]      # random lane-change error in metres
const SWAY := [0.0, 0.0, 0.0, 0.5]          # slow involuntary drifting in metres
const LEVEL_MSGS := [
	"",
	"Alcohol level 1\nYour reactions are getting slower...",
	"Alcohol level 2\nThe world sways. Lane changes get sloppy...",
	"Alcohol level 3\nBlurred, narrow vision. Delayed reactions.",
]
const LEVEL_COLORS := [Color.WHITE, Color(1, 0.9, 0.3), Color(1, 0.6, 0.2), Color(1, 0.25, 0.2)]

const FX_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float blur = 0.0;
uniform float split = 0.0;
uniform float vignette = 0.0;
void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 c = textureLod(screen_tex, uv, blur).rgb;
	vec3 a = textureLod(screen_tex, uv + vec2(split, 0.0), blur).rgb;
	vec3 b = textureLod(screen_tex, uv - vec2(split, 0.0), blur).rgb;
	vec3 col = (c + a + b) / 3.0;
	float v = 1.0 - smoothstep(0.3, 0.85, length(uv - vec2(0.5)));
	col *= mix(1.0, v, vignette);
	COLOR = vec4(col, 1.0);
}
"""

static var auto_start := false     # survives scene reload, so restart skips the menu
static var best_score := 0         # survives scene reload


class Hazard:
	var node: Node3D
	var type := 0              # 0 = vehicle, 1 = obstacle, 2 = pedestrian
	var half := Vector2.ONE
	var vel := Vector3.ZERO
	var waiting := false       # pedestrians wait on the curb until triggered
	var side := 1.0
	var trigger := 2.0         # seconds before the player arrives that the pedestrian starts
	var phase := 0.0
	var scored := false
	var threat := false        # was in the player's path -> counts as a risk
	var min_gap := 99.0
	var reason := ""


var state := State.MENU
var player: Node3D
var camera: Camera3D
var ground: MeshInstance3D
var chunks: Array = []
var hazards: Array = []

var speed := START_SPEED
var play_time := 0.0
var score := 0
var score_timer := 0.0
var segments_done := 0
var level := 0
var drunk := 0.0               # smoothed alcohol level (0..3)
var lane := 0
var lane_offset := 0.0
var pending: Array = []        # delayed steering commands
var spawn_z := -100.0
var cam_x := 0.0
var over_time := 0.0           # when the game ended (restart lockout)

# HUD
var score_label: Label
var speed_label: Label
var alcohol_label: Label
var popup_label: Label
var center_label: Label
var dim: ColorRect
var fx_rect: ColorRect
var fx_mat: ShaderMaterial
var popup_tween: Tween


func _ready() -> void:
	randomize()
	_setup_inputs()
	_build_world()
	player = _make_car_model(Color(0.85, 0.1, 0.1))
	add_child(player)
	camera = Camera3D.new()
	camera.far = 600.0
	add_child(camera)
	camera.current = true
	_build_hud()
	_build_post_fx()
	_update_camera(0.016)
	_update_hud()
	if auto_start:
		_start()
	else:
		_show_menu()


# ------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------
func _setup_inputs() -> void:
	_add_action("steer_left", [KEY_A, KEY_LEFT])
	_add_action("steer_right", [KEY_D, KEY_RIGHT])
	_add_action("start", [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_R])


func _add_action(action: String, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	match state:
		State.MENU:
			if event.is_action_pressed("start"):
				_start()
		State.PLAYING:
			if event.is_action_pressed("steer_left"):
				_queue_steer(-1)
			elif event.is_action_pressed("steer_right"):
				_queue_steer(1)
		State.GAME_OVER:
			# short lockout so mashing A/D at the moment of the crash can't restart
			if event.is_action_pressed("start") and Time.get_ticks_msec() / 1000.0 - over_time > 0.8:
				auto_start = true
				get_tree().reload_current_scene()


# ------------------------------------------------------------------------------
# Game flow
# ------------------------------------------------------------------------------
func _show_menu() -> void:
	dim.visible = true
	center_label.visible = true
	center_label.text = "ONE MORE DRINK\n\nSurvive the road. Avoid cars, obstacles and pedestrians.\nThe farther you go, the more you drink.\n\nA / D  or  Left / Right  -  change lane\n\n+1 pt per second   +10 close call   +50 segment completed\nCrash, hit a pedestrian or leave the road = GAME OVER\n\nPress ENTER to start"


func _start() -> void:
	state = State.PLAYING
	dim.visible = false
	center_label.visible = false
	speed = START_SPEED
	_popup("Go! Stay on the road.", Color.WHITE)


func _game_over(reason: String) -> void:
	state = State.GAME_OVER
	over_time = Time.get_ticks_msec() / 1000.0
	var new_best := score > best_score
	best_score = maxi(best_score, score)
	dim.visible = true
	center_label.visible = true
	center_label.text = "GAME OVER\n%s\n\nScore: %d%s   (Best: %d)\nDistance: %d m\nAlcohol level reached: %d / 3\n\nAlcohol slows reactions, narrows vision and ruins judgement.\nIt is never worth the risk. Don't drink and drive.\n\nPress ENTER to try again" % [
		reason, score, "  NEW BEST!" if new_best else "", best_score, int(-player.position.z), level]


func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	if state == State.PLAYING:
		_update_game(delta)
	_update_camera(delta)


func _update_game(delta: float) -> void:
	play_time += delta
	speed = minf(speed + ACCEL * delta, MAX_SPEED)
	player.position.z -= speed * delta
	drunk = move_toward(drunk, float(level), delta * 0.4)

	_process_steer_queue()
	_update_player_x(delta)

	_spawn_hazards()
	_update_hazards(delta)
	if state != State.PLAYING:
		return

	if absf(player.position.x) > OFFROAD_LIMIT:
		_game_over("You left the road.")
		return

	_update_progress(delta)
	_update_chunks()
	ground.position.z = player.position.z
	_update_hud()


# ------------------------------------------------------------------------------
# Steering with alcohol effects
# ------------------------------------------------------------------------------
func _by_level(table: Array, v: float) -> float:
	var i := clampi(int(floorf(v)), 0, table.size() - 2)
	return lerpf(table[i], table[i + 1], clampf(v - i, 0.0, 1.0))


func _queue_steer(dir: int) -> void:
	pending.append({"t": play_time + _by_level(DELAY, drunk), "dir": dir})


func _process_steer_queue() -> void:
	while pending.size() > 0 and pending[0]["t"] <= play_time:
		var cmd = pending.pop_front()
		_apply_steer(cmd["dir"])


func _apply_steer(dir: int) -> void:
	var new_lane := clampi(lane + dir, -1, 1)
	if new_lane == lane:
		return                                  # no lane change -> no new error
	lane = new_lane
	# Level 2+: you don't land exactly in the middle of the lane
	var err := _by_level(LANE_ERR, drunk)
	lane_offset = randf_range(-err, err)
	# outer lanes: errors toward the road edge are much smaller (keeps it fair)
	if lane != 0 and signf(lane_offset) == float(lane):
		lane_offset *= 0.4


func _update_player_x(delta: float) -> void:
	var sway := sin(play_time * 0.9) * _by_level(SWAY, drunk)
	var target := lane * LANE_WIDTH + lane_offset + sway
	var before := player.position.x
	player.position.x = move_toward(before, target, LATERAL_SPEED * delta)
	var vx := (player.position.x - before) / maxf(delta, 0.0001)
	player.rotation.y = lerp_angle(player.rotation.y, -vx * 0.03, minf(1.0, delta * 10.0))


# ------------------------------------------------------------------------------
# Hazards
# ------------------------------------------------------------------------------
func _spawn_hazards() -> void:
	var horizon := player.position.z - SPAWN_AHEAD
	while spawn_z > horizon:
		_spawn_row(spawn_z)
		spawn_z -= maxf(MIN_GAP, speed * randf_range(1.2, 2.0))


func _spawn_row(z: float) -> void:
	var lanes := [-1, 0, 1]
	lanes.shuffle()
	var r := randf()
	if r < 0.4:
		_spawn_vehicle(lanes[0], z)
	elif r < 0.65:
		_spawn_obstacle(lanes[0], z)
		if randf() < 0.3:
			_spawn_obstacle(lanes[1], z)      # third lane always stays free
	elif r < 0.85:
		_spawn_pedestrian(z)
	else:
		_spawn_vehicle(lanes[0], z)
		_spawn_obstacle(lanes[1], z + randf_range(-6.0, 6.0))


func _spawn_vehicle(lane_i: int, z: float) -> void:
	var h := Hazard.new()
	h.type = 0
	h.half = Vector2(0.9, 2.0)
	h.reason = "You crashed into another vehicle."
	var colors := [Color(0.1, 0.3, 0.8), Color(0.9, 0.9, 0.9), Color(0.1, 0.6, 0.3),
			Color(0.9, 0.7, 0.1), Color(0.3, 0.3, 0.35)]
	h.node = _make_car_model(colors[randi() % colors.size()])
	h.node.position = Vector3(lane_i * LANE_WIDTH, 0.0, z)
	h.vel = Vector3(0, 0, -randf_range(7.0, 12.0))    # slower traffic, same direction
	add_child(h.node)
	hazards.append(h)


func _spawn_obstacle(lane_i: int, z: float) -> void:
	var h := Hazard.new()
	h.type = 1
	h.reason = "You hit an obstacle."
	var n := Node3D.new()
	match randi() % 3:
		0:  # barrel
			_add_cyl(n, 0.45, 1.0, Vector3(0, 0.5, 0), Color(0.9, 0.4, 0.1))
			_add_cyl(n, 0.46, 0.15, Vector3(0, 0.5, 0), Color(0.95, 0.95, 0.95))
			h.half = Vector2(0.45, 0.45)
		1:  # cone
			var cone := _add_cyl(n, 0.35, 0.9, Vector3(0, 0.45, 0), Color(1.0, 0.45, 0.0))
			(cone.mesh as CylinderMesh).top_radius = 0.03
			h.half = Vector2(0.35, 0.35)
		_:  # road barrier
			_add_box(n, Vector3(2.6, 0.9, 0.4), Vector3(0, 0.75, 0), Color(0.9, 0.9, 0.9))
			_add_box(n, Vector3(2.6, 0.25, 0.41), Vector3(0, 0.9, 0), Color(0.9, 0.1, 0.1))
			_add_box(n, Vector3(0.15, 0.6, 0.15), Vector3(-1.1, 0.3, 0), Color(0.3, 0.3, 0.3))
			_add_box(n, Vector3(0.15, 0.6, 0.15), Vector3(1.1, 0.3, 0), Color(0.3, 0.3, 0.3))
			h.half = Vector2(1.3, 0.3)
	n.position = Vector3(lane_i * LANE_WIDTH, 0.0, z)
	h.node = n
	add_child(n)
	hazards.append(h)


func _spawn_pedestrian(z: float) -> void:
	var h := Hazard.new()
	h.type = 2
	h.half = Vector2(0.35, 0.35)
	h.reason = "You hit a pedestrian."
	h.waiting = true
	h.side = 1.0 if randf() < 0.5 else -1.0
	h.trigger = randf_range(1.6, 3.4)
	h.phase = randf() * TAU
	var n := Node3D.new()
	var col := Color.from_hsv(randf(), 0.6, 0.9)
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.25
	cap.height = 1.6
	body.mesh = cap
	body.material_override = _mat(col)
	body.position.y = 0.8
	n.add_child(body)
	var head := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	head.mesh = sph
	head.material_override = _mat(Color(0.9, 0.75, 0.6))
	head.position.y = 1.8
	n.add_child(head)
	n.position = Vector3(h.side * 6.5, 0.1, z)
	h.node = n
	add_child(n)
	hazards.append(h)


func _update_hazards(delta: float) -> void:
	for i in range(hazards.size() - 1, -1, -1):
		var h: Hazard = hazards[i]
		var n := h.node

		# Pedestrians start crossing when the player gets close
		if h.type == 2:
			if h.waiting and player.position.z - n.position.z < speed * h.trigger:
				h.waiting = false
				h.vel = Vector3(-h.side * PED_SPEED, 0, 0)
			if not h.waiting:
				n.position.y = 0.1 + absf(sin(play_time * 9.0 + h.phase)) * 0.08
				if (h.side > 0.0 and n.position.x < -7.2) or (h.side < 0.0 and n.position.x > 7.2):
					h.vel = Vector3.ZERO

		n.position += h.vel * delta

		var dx := n.position.x - player.position.x
		var dz := n.position.z - player.position.z
		var reach_x := h.half.x + PLAYER_HALF.x
		var reach_z := h.half.y + PLAYER_HALF.y

		# Collision = Game Over
		if absf(dx) < reach_x and absf(dz) < reach_z:
			_game_over(h.reason)
			return

		# Was this hazard a real risk for the player?
		if dz < 0.0 and dz > -60.0 and absf(dx) < reach_x + 0.5:
			h.threat = true
		if absf(dz) < 7.0:
			h.min_gap = minf(h.min_gap, absf(dx) - reach_x)

		# Hazard passed (it is now behind the player) -> close call bonus
		if not h.scored and dz > reach_z + 1.0:
			h.scored = true
			if h.threat or h.min_gap < 1.0:
				score += 10
				_popup("Close call!  +10", Color(0.4, 1.0, 0.5))

		if dz > 40.0:
			n.queue_free()
			hazards.remove_at(i)


# ------------------------------------------------------------------------------
# Score and route progress
# ------------------------------------------------------------------------------
func _update_progress(delta: float) -> void:
	score_timer += delta
	while score_timer >= 1.0:
		score_timer -= 1.0
		score += 1

	var seg_now := int(-player.position.z / SEGMENT_LENGTH)
	if seg_now > segments_done:
		segments_done = seg_now
		score += 50
		var text := "Segment %d complete!  +50" % segments_done
		var color := Color(0.4, 0.8, 1.0)
		var new_level := mini(segments_done, 3)
		if new_level != level:
			level = new_level
			text += "\n" + LEVEL_MSGS[level]
			color = LEVEL_COLORS[level]
		_popup(text, color)


# ------------------------------------------------------------------------------
# Camera + post effects (wobble, FOV, blur)
# ------------------------------------------------------------------------------
func _update_camera(delta: float) -> void:
	var k2 := clampf(drunk - 1.0, 0.0, 2.0)    # wobble: small at lvl 2, bigger at lvl 3
	var k3 := clampf(drunk - 2.0, 0.0, 1.0)    # blur / FOV only at lvl 3
	var t := Time.get_ticks_msec() / 1000.0

	cam_x = lerpf(cam_x, player.position.x * 0.6, minf(1.0, delta * 6.0))
	var wobble := Vector3(sin(t * 0.9) * 0.3, sin(t * 1.3) * 0.12, 0.0) * k2
	camera.position = Vector3(cam_x + wobble.x, 3.4 + wobble.y, player.position.z + 7.5)
	camera.look_at(Vector3(cam_x, 1.2, player.position.z - 14.0), Vector3.UP)
	camera.rotate_object_local(Vector3.BACK, (sin(t * 1.1) * 0.03 + sin(t * 0.37) * 0.015) * k2)

	var target_fov := BASE_FOV + clampf((speed - START_SPEED) * 0.2, 0.0, 8.0) - 22.0 * k3
	camera.fov = lerpf(camera.fov, target_fov, minf(1.0, delta * 3.0))

	fx_rect.visible = k3 > 0.01
	fx_mat.set_shader_parameter("blur", k3 * 2.4)
	fx_mat.set_shader_parameter("split", k3 * 0.007)
	fx_mat.set_shader_parameter("vignette", k3 * 0.75)


# ------------------------------------------------------------------------------
# HUD
# ------------------------------------------------------------------------------
func _make_label(font_size: int, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.horizontal_alignment = align
	return l


func _build_hud() -> void:
	var hud := CanvasLayer.new()
	hud.layer = 2
	add_child(hud)

	dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	score_label = _make_label(28, HORIZONTAL_ALIGNMENT_LEFT)
	hud.add_child(score_label)
	score_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 20)

	speed_label = _make_label(28, HORIZONTAL_ALIGNMENT_RIGHT)
	hud.add_child(speed_label)
	speed_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 20)

	alcohol_label = _make_label(28, HORIZONTAL_ALIGNMENT_CENTER)
	hud.add_child(alcohol_label)
	alcohol_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 20)

	popup_label = _make_label(34, HORIZONTAL_ALIGNMENT_CENTER)
	popup_label.modulate.a = 0.0
	hud.add_child(popup_label)
	popup_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 20)
	popup_label.offset_top = 110.0

	center_label = _make_label(30, HORIZONTAL_ALIGNMENT_CENTER)
	center_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud.add_child(center_label)
	center_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _update_hud() -> void:
	score_label.text = "Score  %d\nSegment %d   %d / %d m" % [
		score, segments_done + 1, int(-player.position.z) % int(SEGMENT_LENGTH), int(SEGMENT_LENGTH)]
	speed_label.text = "%d km/h" % int(speed * 3.6)
	alcohol_label.text = "ALCOHOL  [%s%s]" % ["#".repeat(level), "-".repeat(3 - level)]
	alcohol_label.add_theme_color_override("font_color", LEVEL_COLORS[level])


func _popup(text: String, color: Color) -> void:
	popup_label.text = text
	popup_label.modulate = Color(color, 1.0)
	if popup_tween:
		popup_tween.kill()
	popup_tween = create_tween()
	popup_tween.tween_interval(1.6)
	popup_tween.tween_property(popup_label, "modulate:a", 0.0, 0.6)


func _build_post_fx() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1                       # below the HUD so text stays sharp
	add_child(layer)
	fx_rect = ColorRect.new()
	fx_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = FX_SHADER
	fx_mat = ShaderMaterial.new()
	fx_mat.shader = shader
	fx_rect.material = fx_mat
	layer.add_child(fx_rect)
	fx_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fx_rect.visible = false


# ------------------------------------------------------------------------------
# World building (endless road = chunks recycled in front of the player)
# ------------------------------------------------------------------------------
func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.8, 0.9)
	env.fog_density = 0.008
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)

	ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1200, 1200)
	ground.mesh = plane
	ground.material_override = _mat(Color(0.25, 0.5, 0.2))
	ground.position.y = -0.15
	add_child(ground)

	for i in range(NUM_CHUNKS):
		var c := _make_chunk(i)
		add_child(c)
		chunks.append(c)


func _make_chunk(i: int) -> Node3D:
	var c := Node3D.new()
	c.position.z = 100.0 - i * CHUNK_LEN
	_add_box(c, Vector3(ROAD_HALF * 2.0, 0.2, CHUNK_LEN), Vector3(0, -0.1, 0), Color(0.16, 0.16, 0.18))
	for s in [-1, 1]:
		_add_box(c, Vector3(0.15, 0.02, CHUNK_LEN), Vector3(s * (ROAD_HALF - 0.25), 0.011, 0), Color(0.9, 0.9, 0.9))
		_add_box(c, Vector3(2.5, 0.25, CHUNK_LEN), Vector3(s * 6.5, 0.0, 0), Color(0.55, 0.55, 0.55))
		for k in range(4):
			var pz := -37.5 + k * 25.0
			_add_cyl(c, 0.1, 6.0, Vector3(s * 8.2, 3.0, pz), Color(0.3, 0.3, 0.3))
			_add_box(c, Vector3(1.8, 0.15, 0.4), Vector3(s * 7.4, 6.0, pz), Color(1.0, 0.95, 0.7), true)
		for k in range(3):
			var tx: float = s * randf_range(10.0, 17.0)
			var tz := randf_range(-50.0, 50.0)
			_add_cyl(c, 0.3, 2.0, Vector3(tx, 1.0, tz), Color(0.4, 0.25, 0.1))
			var crown := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 1.6
			sm.height = 3.2
			crown.mesh = sm
			crown.material_override = _mat(Color(0.12, 0.4, 0.15))
			crown.position = Vector3(tx, 3.2, tz)
			c.add_child(crown)
	for lx in [-1.75, 1.75]:
		for k in range(10):
			_add_box(c, Vector3(0.15, 0.02, 3.0), Vector3(lx, 0.011, -45.0 + k * 10.0), Color(0.9, 0.9, 0.9))
	return c


func _update_chunks() -> void:
	for c in chunks:
		if c.position.z - player.position.z > CHUNK_LEN * 1.5:
			c.position.z -= CHUNK_LEN * NUM_CHUNKS


# ------------------------------------------------------------------------------
# Model helpers
# ------------------------------------------------------------------------------
func _make_car_model(color: Color) -> Node3D:
	var car := Node3D.new()
	_add_box(car, Vector3(1.8, 0.6, 4.0), Vector3(0, 0.6, 0), color)
	_add_box(car, Vector3(1.6, 0.5, 1.9), Vector3(0, 1.15, 0.3), Color(0.15, 0.2, 0.25))
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var w := _add_cyl(car, 0.4, 0.3, Vector3(sx * 0.95, 0.4, sz * 1.3), Color(0.05, 0.05, 0.05))
			w.rotation_degrees.z = 90.0
		_add_box(car, Vector3(0.4, 0.18, 0.06), Vector3(sx * 0.6, 0.7, 2.02), Color(1.0, 0.1, 0.1), true)
	return car


func _mat(color: Color, emissive := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.5
	return m


func _add_box(parent: Node, size: Vector3, pos: Vector3, color: Color, emissive := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color, emissive)
	mi.position = pos
	parent.add_child(mi)
	return mi


func _add_cyl(parent: Node, radius: float, height: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	mi.mesh = cm
	mi.material_override = _mat(color)
	mi.position = pos
	parent.add_child(mi)
	return mi
