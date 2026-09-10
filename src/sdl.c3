// Minimal hand-written SDL3 binding — only what src/display.c3 needs.
// Links against the system libSDL3 (see project.json "linked-libraries").
module sdl;

alias Window = void;
alias Renderer = void;
alias Texture = void;
alias AudioStream = void;

// SDL_Init flags
const uint INIT_AUDIO  = 0x00000010;
const uint INIT_VIDEO  = 0x00000020;
const uint INIT_EVENTS = 0x00004000;

// SDL_AudioFormat / default playback device
const uint AUDIO_S16                     = 0x8010; // little-endian
const uint AUDIO_DEVICE_DEFAULT_PLAYBACK = 0xFFFFFFFF;

struct AudioSpec {
	uint format; // SDL_AudioFormat
	int  channels;
	int  freq;
}

// SDL_EventType
const uint EVENT_QUIT     = 0x100;
const uint EVENT_KEY_DOWN = 0x300;
const uint EVENT_KEY_UP   = 0x301;

// SDL_PixelFormat / SDL_TextureAccess / SDL_ScaleMode
const uint PIXELFORMAT_ABGR8888   = 0x16762004; // memory order R,G,B,A
const int  TEXTUREACCESS_STREAMING = 1;
const int  SCALEMODE_NEAREST       = 0;

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

// We only ever read event.type; the SDL_Event union is 128 bytes.
struct Event {
	uint type;
	char[124] pad;
}

extern fn int      init(uint flags)          @cname("SDL_Init");
extern fn void     quit()                    @cname("SDL_Quit");
extern fn ZString  get_error()               @cname("SDL_GetError");
extern fn void     delay(uint ms)            @cname("SDL_Delay");

extern fn Window*   create_window(ZString title, int w, int h, ulong flags) @cname("SDL_CreateWindow");
extern fn void      destroy_window(Window* window)                          @cname("SDL_DestroyWindow");

extern fn Renderer* create_renderer(Window* window, ZString name)   @cname("SDL_CreateRenderer");
extern fn void      destroy_renderer(Renderer* renderer)            @cname("SDL_DestroyRenderer");
extern fn int       render_clear(Renderer* renderer)                @cname("SDL_RenderClear");
extern fn int       render_present(Renderer* renderer)              @cname("SDL_RenderPresent");
extern fn int       render_texture(Renderer* r, Texture* t, void* src, void* dst) @cname("SDL_RenderTexture");
extern fn int       set_render_vsync(Renderer* renderer, int vsync) @cname("SDL_SetRenderVSync");

extern fn Texture*  create_texture(Renderer* r, uint format, int access, int w, int h) @cname("SDL_CreateTexture");
extern fn void      destroy_texture(Texture* t)                       @cname("SDL_DestroyTexture");
extern fn int       update_texture(Texture* t, void* rect, void* pixels, int pitch) @cname("SDL_UpdateTexture");
extern fn int       set_texture_scale_mode(Texture* t, int mode)      @cname("SDL_SetTextureScaleMode");

extern fn bool      poll_event(Event* event)          @cname("SDL_PollEvent");
extern fn char*     get_keyboard_state(int* numkeys)  @cname("SDL_GetKeyboardState");

extern fn AudioStream* open_audio_device_stream(uint devid, AudioSpec* spec, void* cb, void* userdata) @cname("SDL_OpenAudioDeviceStream");
extern fn bool         resume_audio_stream_device(AudioStream* s)          @cname("SDL_ResumeAudioStreamDevice");
extern fn bool         put_audio_stream_data(AudioStream* s, void* buf, int len) @cname("SDL_PutAudioStreamData");
extern fn int          get_audio_stream_queued(AudioStream* s)             @cname("SDL_GetAudioStreamQueued");
extern fn void         destroy_audio_stream(AudioStream* s)                @cname("SDL_DestroyAudioStream");
