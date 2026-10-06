// Minimal hand-written SDL3 binding — only what src/display.c3 needs.
// Links against the system libSDL3 (see project.json "linked-libraries").
module sdl;

alias Window = void;
alias Renderer = void;
alias Texture = void;
alias AudioStream = void;
alias Gamepad = void;

// SDL_Init flags
const uint INIT_AUDIO  = 0x00000010;
const uint INIT_VIDEO  = 0x00000020;
const uint INIT_EVENTS = 0x00004000;
const uint INIT_GAMEPAD = 0x00002000;
const uint INIT_HAPTIC  = 0x00001000;
const uint INIT_SENSOR  = 0x00008000;
const uint INIT_CAMERA  = 0x00010000;

// SDL_AudioFormat / default playback device
const uint AUDIO_S16                     = 0x8010; // little-endian
const uint AUDIO_DEVICE_DEFAULT_PLAYBACK = 0xFFFFFFFF;

struct AudioSpec {
	uint format; // SDL_AudioFormat
	int  channels;
	int  freq;
}

// SDL_EventType
const ulong WINDOW_RESIZABLE = 0x20;

const uint EVENT_QUIT     = 0x100;
const uint EVENT_TERMINATING           = 0x101;
const uint EVENT_WILL_ENTER_BACKGROUND = 0x103;
const uint EVENT_DID_ENTER_BACKGROUND  = 0x104;
const uint EVENT_KEY_DOWN = 0x300;
const uint EVENT_KEY_UP   = 0x301;
const uint EVENT_TEXT_INPUT = 0x303;
const uint EVENT_GAMEPAD_AXIS_MOTION = 0x650;
const uint EVENT_GAMEPAD_BUTTON_DOWN = 0x651;
const uint EVENT_GAMEPAD_BUTTON_UP   = 0x652;
const uint EVENT_GAMEPAD_ADDED       = 0x653;
const uint EVENT_GAMEPAD_REMOVED     = 0x654;
const uint EVENT_FINGER_DOWN     = 0x700;
const uint EVENT_FINGER_UP       = 0x701;
const uint EVENT_FINGER_MOTION   = 0x702;
const uint EVENT_FINGER_CANCELED = 0x703;

// SDL_GamepadButton / SDL_GamepadAxis values used directly
const int GAMEPAD_BUTTON_INVALID    = -1;
const int GAMEPAD_BUTTON_SOUTH      = 0;
const int GAMEPAD_BUTTON_EAST       = 1;
const int GAMEPAD_BUTTON_BACK       = 4;
const int GAMEPAD_BUTTON_GUIDE      = 5;
const int GAMEPAD_BUTTON_START      = 6;
const int GAMEPAD_BUTTON_LEFT_SHOULDER  = 9;
const int GAMEPAD_BUTTON_RIGHT_SHOULDER = 10;
const int GAMEPAD_BUTTON_DPAD_UP    = 11;
const int GAMEPAD_BUTTON_DPAD_DOWN  = 12;
const int GAMEPAD_BUTTON_DPAD_LEFT  = 13;
const int GAMEPAD_BUTTON_DPAD_RIGHT = 14;
const int GAMEPAD_AXIS_LEFTX = 0;
const int GAMEPAD_AXIS_LEFTY = 1;

// SDL_PixelFormat / SDL_TextureAccess / SDL_ScaleMode
const uint PIXELFORMAT_ABGR8888   = 0x16762004; // memory order R,G,B,A
const int  TEXTUREACCESS_STREAMING = 1;
const int  SCALEMODE_NEAREST       = 0;
const int  SCALEMODE_LINEAR        = 1;
const int  SCALEMODE_PIXELART      = 2; // SDL 3.4

// SDL_Scancode values used for input mapping
const int SC_A      = 4;
const int SC_S      = 22;
const int SC_X      = 27;
const int SC_Z      = 29;
const int SC_RETURN = 40;
const int SC_ESCAPE = 41;
const int SC_RIGHT  = 79;
const int SC_LEFT   = 80;
const int SC_DOWN   = 81;
const int SC_UP     = 82;
const int SC_RSHIFT = 229;

const int SC_O      = 18;
const int SC_N      = 17;
const int SC_P      = 19;
const int SC_TAB    = 43;
const int SC_R      = 21;
const int SC_GRAVE  = 53;
const int SC_BACKSPACE = 42;
const int SC_AC_BACK = 282; // Android's Back
const int SC_F1     = 58; // F1-F9 are consecutive
const int SC_F9     = 66;
const int SC_F12    = 69;

// SDL_Keymod: either Ctrl / either Shift key
const ushort KMOD_CTRL  = 0x00C0;
const ushort KMOD_SHIFT = 0x0003;

// The SDL_Event union is 128 bytes; we read `type`, and for key events view
// the same memory as a KeyboardEvent.
struct Event {
	uint type;
	char[124] pad;
}

struct KeyboardEvent {
	uint   type;
	uint   reserved;
	ulong  timestamp;
	uint   window_id;
	uint   which;
	uint   scancode;
	uint   key;
	ushort mod;
	ushort raw;
	bool   down;
	bool   repeat;
}

struct TextInputEvent {
	uint    type;
	uint    reserved;
	ulong   timestamp;
	uint    window_id;
	ZString text;      // UTF-8
}

struct GamepadButtonEvent {
	uint  type;
	uint  reserved;
	ulong timestamp;
	uint  which;   // joystick instance id
	char  button;  // SDL_GamepadButton
	bool  down;
	char  padding1;
	char  padding2;
}

struct GamepadAxisEvent {
	uint  type;
	uint  reserved;
	ulong timestamp;
	uint  which;
	char  axis;    // SDL_GamepadAxis
	char  padding1;
	char  padding2;
	char  padding3;
	short value;
	ushort padding4;
}

struct TouchFingerEvent {
	uint  type;
	uint  reserved;
	ulong timestamp;
	ulong touch_id;
	ulong finger_id;
	float x;          // 0..1 of the window
	float y;
	float dx;
	float dy;
	float pressure;
	uint  window_id;
}

struct GamepadDeviceEvent {
	uint  type;
	uint  reserved;
	ulong timestamp;
	uint  which;
}

// SDL_BlendMode
const uint BLENDMODE_BLEND = 0x00000001;

struct FRect {
	float x;
	float y;
	float w;
	float h;
}

// Native file dialog (SDL_dialog.h). The callback gets a NULL-terminated list
// of paths (empty if cancelled, NULL on error) and may run on another thread.
struct DialogFileFilter {
	ZString name;
	ZString pattern; // e.g. "gb;gbc"
}

alias DialogFileCallback = fn void(void* userdata, ZString* filelist, int filter);

extern fn int      init(uint flags)          @cname("SDL_Init");
extern fn void     quit()                    @cname("SDL_Quit");
extern fn ZString  get_error()               @cname("SDL_GetError");
extern fn void     delay(uint ms)            @cname("SDL_Delay");
extern fn void*    load_file(ZString file, usz* size) @cname("SDL_LoadFile");
extern fn void     free(void* mem)           @cname("SDL_free");
extern fn ZString  get_pref_path(ZString org, ZString app) @cname("SDL_GetPrefPath");

extern fn Window*   create_window(ZString title, int w, int h, ulong flags) @cname("SDL_CreateWindow");
extern fn void      destroy_window(Window* window)                          @cname("SDL_DestroyWindow");
extern fn bool      set_window_title(Window* window, ZString title)         @cname("SDL_SetWindowTitle");
extern fn bool      set_window_size(Window* window, int w, int h)           @cname("SDL_SetWindowSize");
extern fn bool      set_window_icon(Window* window, Surface* icon)          @cname("SDL_SetWindowIcon");
extern fn Surface*  create_surface_from(int w, int h, uint format, void* pixels, int pitch) @cname("SDL_CreateSurfaceFrom");
extern fn void      destroy_surface(Surface* surface)                       @cname("SDL_DestroySurface");

extern fn void      show_open_file_dialog(DialogFileCallback callback, void* userdata, Window* window,
                        DialogFileFilter* filters, int nfilters, ZString default_location,
                        bool allow_many) @cname("SDL_ShowOpenFileDialog");

extern fn Renderer* create_renderer(Window* window, ZString name)   @cname("SDL_CreateRenderer");
extern fn void      destroy_renderer(Renderer* renderer)            @cname("SDL_DestroyRenderer");
extern fn int       render_clear(Renderer* renderer)                @cname("SDL_RenderClear");
extern fn int       render_present(Renderer* renderer)              @cname("SDL_RenderPresent");
extern fn int       render_texture(Renderer* r, Texture* t, void* src, void* dst) @cname("SDL_RenderTexture");
extern fn int       set_render_vsync(Renderer* renderer, int vsync) @cname("SDL_SetRenderVSync");
extern fn bool      set_render_scale(Renderer* r, float sx, float sy) @cname("SDL_SetRenderScale");
extern fn bool      set_render_draw_color(Renderer* r, char red, char green, char blue, char alpha) @cname("SDL_SetRenderDrawColor");
extern fn bool      set_render_draw_blend_mode(Renderer* r, uint mode) @cname("SDL_SetRenderDrawBlendMode");
extern fn bool      render_fill_rect(Renderer* r, FRect* rect)      @cname("SDL_RenderFillRect");
extern fn bool      render_rect(Renderer* r, FRect* rect)           @cname("SDL_RenderRect");
extern fn bool      render_fill_rects(Renderer* r, FRect* rects, int count) @cname("SDL_RenderFillRects");
extern fn bool      get_render_output_size(Renderer* r, int* w, int* h) @cname("SDL_GetRenderOutputSize");
extern fn bool      set_hint(ZString name, ZString value)          @cname("SDL_SetHint");
extern fn bool      set_window_fullscreen(Window* w, bool on)       @cname("SDL_SetWindowFullscreen");
// SDL 3.4+, Emscripten only (the canvas takes the whole page).
extern fn bool      set_window_fill_document(Window* w, bool fill)  @cname("SDL_SetWindowFillDocument");
alias EventFilter = fn bool(void* userdata, Event* event);
extern fn bool      add_event_watch(EventFilter filter, void* userdata) @cname("SDL_AddEventWatch");
extern fn bool      render_debug_text(Renderer* r, float x, float y, ZString text) @cname("SDL_RenderDebugText");

extern fn Texture*  create_texture(Renderer* r, uint format, int access, int w, int h) @cname("SDL_CreateTexture");
extern fn void      destroy_texture(Texture* t)                       @cname("SDL_DestroyTexture");
extern fn int       update_texture(Texture* t, void* rect, void* pixels, int pitch) @cname("SDL_UpdateTexture");
extern fn int       set_texture_scale_mode(Texture* t, int mode)      @cname("SDL_SetTextureScaleMode");

extern fn bool      poll_event(Event* event)          @cname("SDL_PollEvent");
extern fn int       get_scancode_from_name(ZString name) @cname("SDL_GetScancodeFromName");
extern fn ZString   get_scancode_name(int scancode)      @cname("SDL_GetScancodeName");

extern fn Gamepad*  open_gamepad(uint instance_id)               @cname("SDL_OpenGamepad");
extern fn void      close_gamepad(Gamepad* pad)                  @cname("SDL_CloseGamepad");
extern fn uint      get_gamepad_id(Gamepad* pad)                 @cname("SDL_GetGamepadID");
extern fn ZString   get_gamepad_name(Gamepad* pad)               @cname("SDL_GetGamepadName");
extern fn bool      get_gamepad_button(Gamepad* pad, int button) @cname("SDL_GetGamepadButton");
extern fn short     get_gamepad_axis(Gamepad* pad, int axis)     @cname("SDL_GetGamepadAxis");
extern fn int       get_gamepad_button_from_string(ZString str)  @cname("SDL_GetGamepadButtonFromString");
extern fn ZString   get_gamepad_string_for_button(int button)    @cname("SDL_GetGamepadStringForButton");
extern fn char*     get_keyboard_state(int* numkeys)  @cname("SDL_GetKeyboardState");
extern fn bool      start_text_input(Window* w)       @cname("SDL_StartTextInput");
extern fn bool      stop_text_input(Window* w)        @cname("SDL_StopTextInput");
extern fn bool      rumble_gamepad(Gamepad* pad, ushort low, ushort high, uint ms) @cname("SDL_RumbleGamepad");

// Sensors (SDL_sensor.h): a phone's accelerometer, in m/s^2 along the
// device's natural orientation (x right, y up, z out of the screen).
alias Sensor = void;
const int   SENSOR_ACCEL     = 1;
const float STANDARD_GRAVITY = 9.80665;
extern fn uint*    get_sensors(int* count)                       @cname("SDL_GetSensors");
extern fn int      get_sensor_type_for_id(uint id)               @cname("SDL_GetSensorTypeForID");
extern fn Sensor*  open_sensor(uint id)                          @cname("SDL_OpenSensor");
extern fn void     close_sensor(Sensor* s)                       @cname("SDL_CloseSensor");
extern fn bool     get_sensor_data(Sensor* s, float* data, int n) @cname("SDL_GetSensorData");

// SDL_DisplayOrientation
const int ORIENTATION_LANDSCAPE         = 1; // right side up, from portrait
const int ORIENTATION_LANDSCAPE_FLIPPED = 2;
const int ORIENTATION_PORTRAIT          = 3;
const int ORIENTATION_PORTRAIT_FLIPPED  = 4;
extern fn uint     get_display_for_window(Window* w)             @cname("SDL_GetDisplayForWindow");
extern fn int      get_current_display_orientation(uint display) @cname("SDL_GetCurrentDisplayOrientation");
extern fn int      get_natural_display_orientation(uint display) @cname("SDL_GetNaturalDisplayOrientation");

// Cameras (SDL_camera.h): webcams, a phone's cameras, the browser's.
alias Camera = void;
struct CameraSpec {
	uint format;
	int  colorspace;
	int  width;
	int  height;
	int  framerate_numerator;
	int  framerate_denominator;
}
struct Surface {
	uint  flags;
	uint  format;
	int   w;
	int   h;
	int   pitch;
	void* pixels;
	int   refcount;
	void* reserved;
}
const uint PIXELFORMAT_XRGB8888 = 0x16161804;
const uint PIXELFORMAT_RGB24    = 0x17101803;
const uint PIXELFORMAT_MJPG     = 0x47504a4d;
const int  CAMERA_POSITION_FRONT_FACING = 1;
const ZString PROP_SURFACE_ROTATION_FLOAT = "SDL.surface.rotation";
extern fn bool     init_subsystem(uint flags)                   @cname("SDL_InitSubSystem");
extern fn uint*    get_cameras(int* count)                      @cname("SDL_GetCameras");
extern fn int      get_camera_position(uint id)                 @cname("SDL_GetCameraPosition");
extern fn CameraSpec** get_camera_supported_formats(uint id, int* count) @cname("SDL_GetCameraSupportedFormats");
extern fn Camera*  open_camera(uint id, CameraSpec* spec)       @cname("SDL_OpenCamera");
extern fn void     close_camera(Camera* c)                      @cname("SDL_CloseCamera");
extern fn Surface* acquire_camera_frame(Camera* c, ulong* timestamp_ns) @cname("SDL_AcquireCameraFrame");
extern fn void     release_camera_frame(Camera* c, Surface* frame) @cname("SDL_ReleaseCameraFrame");
extern fn Surface* convert_surface(Surface* s, uint format)     @cname("SDL_ConvertSurface");
extern fn Surface* render_read_pixels(Renderer* r, Rect* rect)  @cname("SDL_RenderReadPixels");
struct Rect {
	int x;
	int y;
	int w;
	int h;
}
extern fn uint     get_surface_properties(Surface* s)           @cname("SDL_GetSurfaceProperties");
extern fn float    get_float_property(uint props, ZString name, float default_value) @cname("SDL_GetFloatProperty");

// Force feedback (SDL_haptic.h): a phone's vibration motor.
alias Haptic = void;
extern fn uint*    get_haptics(int* count)                       @cname("SDL_GetHaptics");
extern fn Haptic*  open_haptic(uint id)                          @cname("SDL_OpenHaptic");
extern fn void     close_haptic(Haptic* h)                       @cname("SDL_CloseHaptic");
extern fn bool     init_haptic_rumble(Haptic* h)                 @cname("SDL_InitHapticRumble");
extern fn bool     play_haptic_rumble(Haptic* h, float strength, uint ms) @cname("SDL_PlayHapticRumble");
extern fn bool     stop_haptic_rumble(Haptic* h)                 @cname("SDL_StopHapticRumble");

extern fn AudioStream* open_audio_device_stream(uint devid, AudioSpec* spec, void* cb, void* userdata) @cname("SDL_OpenAudioDeviceStream");
extern fn bool         resume_audio_stream_device(AudioStream* s)          @cname("SDL_ResumeAudioStreamDevice");
extern fn bool         put_audio_stream_data(AudioStream* s, void* buf, int len) @cname("SDL_PutAudioStreamData");
extern fn int          get_audio_stream_queued(AudioStream* s)             @cname("SDL_GetAudioStreamQueued");
extern fn bool         clear_audio_stream(AudioStream* s)                  @cname("SDL_ClearAudioStream");
extern fn void         destroy_audio_stream(AudioStream* s)                @cname("SDL_DestroyAudioStream");
