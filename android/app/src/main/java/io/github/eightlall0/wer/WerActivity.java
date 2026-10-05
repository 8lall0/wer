package io.github.eightlall0.wer;

import org.libsdl.app.SDLActivity;

// wer's activity: SDL's, loading libSDL3.so and libmain.so (wer), whose
// SDL_main is src/android.c3.
public class WerActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL3", "main" };
    }
}
