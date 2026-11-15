-- Hand-written notes for tools/gen_api_subset.lua: what the code cannot tell about the LÖVE 11
-- subset the console implements. The generator lists every function, method and callback from
-- the code and gives it "full", or "stub" if it is the runtime's do-nothing function; this file
-- overrides that:
--   name = { "partial", "the limit, in a few words" }
--   name = { "stub", "what it answers" }        exists, does nothing useful
--   name = { "full" }                           a do-nothing function that is the right behaviour
--   _default = { status, note }                 for every function of the module without a note
--   _note = "..."                               a paragraph for the module or type in docs/API_SUBSET.md
-- A note starting with "Checked:" names what tools/compat_check.lua detects from the arguments.
-- A note about a name that does not exist (any more) stops the generator. After changing this
-- file: luajit tools/gen_api_subset.lua
local SCREEN = 'The screen is always 1280x720, fullscreen.'

local texture = {   -- Image and Canvas share one metatable on the console
  setFilter = { 'partial', 'One mode for min and mag (the first argument); no anisotropy. Checked: min and mag differ.' },
}

return {
  -- In the love table and not LÖVE API
  internal = {
    ['love.graphics.sync'] = true,   -- the frame loop's wait for the GPU
    ['love.handlers'] = true,
    ['love.arg'] = true,
  },

  modules = {
    ['love'] = {
      getVersion = { 'partial', 'Always answers 11.5.0.' },
    },

    ['love.graphics'] = {
      _note = 'Everything is transformed on the CPU and batched; see `runtime/README.md` for how draws are '
        .. 'joined and for the per-frame vertex budget (120000 vertices).',
      newImage = { 'partial', 'PNG files only, by file name; no ImageData or CompressedImageData; of the settings only `dpiscale`. '
        .. 'Textures are cached by name and never freed. Checked: not a `.png` file name.' },
      newFont = { 'partial', 'TTF files only, glyphs 32-255 (Latin-1), no kerning; `newFont(size)` needs `default_font` in game.lua. '
        .. 'No hinting or dpiscale arguments. Checked: a file that is not `.ttf`.' },
      setNewFont = { 'partial', 'As `newFont`.' },
      newText = { 'partial', 'One line of text.' },
      newCanvas = { 'partial', 'Always the size of the screen (1280x720), whatever is asked; no settings (format, msaa, mipmaps). '
        .. 'Checked: another size.' },
      setCanvas = { 'partial', 'One canvas, no stencil or depth buffer. Checked: several canvases, `stencil`, `depthstencil`.' },
      newShader = { 'partial', 'Only shaders declared in game.lua and built on PC ([SHADERS.md](SHADERS.md)); anything else draws with the '
        .. 'default shader. Checked: code that is not the text of a declared file; with a game.lua, a file that is not declared.' },
      newSpriteBatch = { 'partial', '`usage` is ignored.' },
      newParticleSystem = { 'partial', 'Each system has its own random generator: not the same particles as on PC, and '
        .. '`love.math.setRandomSeed` does not reach it.' },
      newVideo = { 'stub', 'Returns an object without methods; nothing is played.' },
      draw = { 'partial', 'Image, Canvas, SpriteBatch, ParticleSystem and Text; no Mesh or Video, no Transform argument. '
        .. 'Checked: another kind of object.' },
      clear = { 'partial', 'Only sets the colour the next frame starts with; does not clear a Canvas or the screen mid-frame.' },
      push = { 'partial', 'The transform only. Checked: `push("all")`.' },
      setBlendMode = { 'partial', '`"alpha"` and `"add"` (with `"alphamultiply"` or `"premultiplied"`); the other modes are drawn as '
        .. '`"alpha"`. Checked: another mode.' },
      print = { 'partial', 'Latin-1 only, no tabs; at most 4095 bytes, 256 lines and 32 colour runs per call. Needs a TTF font.' },
      printf = { 'partial', 'As `print`. Wraps at spaces and line breaks.' },
      rectangle = { 'partial', 'No rounded corners. Checked: `rx`/`ry` given.' },
      polygon = { 'partial', 'At most 128 points; filled polygons must be convex. Checked: more points.' },
      line = { 'partial', 'At most 510 points; miter joins, no smoothing. Checked: more points.' },
      circle = { 'partial', 'At most 510 segments.' },
      ellipse = { 'partial', 'At most 510 segments.' },
      points = { 'partial', 'At most 510 points per call.' },
      setDefaultFilter = { 'partial', 'One mode for min and mag (the first argument); no anisotropy. Checked: min and mag differ.' },
      getStats = { 'partial', 'Only `drawcalls` and `texturememory`.' },
      setScissor = { 'stub', 'Accepted, nothing is clipped.' },
      setStencilTest = { 'stub', 'Accepted, there is no stencil.' },
      setColorMask = { 'stub', 'Accepted, every channel is always written.' },
      setLineStyle = { 'stub', 'Accepted, lines are always "rough".' },
      reset = { 'stub', 'Accepted, restores nothing (colour, blend mode, font, shader and transform stay).' },
      present = { 'full' },
    },

    ['love.filesystem'] = {
      _note = 'Reading looks in the save folder first and then in the game folder, as in LÖVE. Everything written goes to '
        .. 'the game\'s save folder (`save_dir` in game.lua), two slots per file.',
      read = { 'partial', 'The whole file as a string. Checked: a container type or a size.' },
      write = { 'partial', 'The whole string; no size argument. Subfolders are flattened into the file name.' },
      append = { 'partial', 'Rewrites the whole file.' },
      getInfo = { 'partial', '`modtime` is always 0; no table argument.' },
      createDirectory = { 'partial', 'Remembered for this run only; nothing is created on disk.' },
      remove = { 'partial', 'Save files and folders made in this run.' },
      getDirectoryItems = { 'partial', 'The game folder and what was saved in this run: saves of earlier runs are not listed.' },
      getSource = { 'partial', 'Always `"."`.' },
      getSourceBaseDirectory = { 'partial', 'Always `"."`.' },
      setIdentity = { 'partial', 'Only changes what `getIdentity` answers; the save folder is game.lua\'s.' },
      load = { 'partial', 'Text chunks only; no mode argument.' },
    },

    ['love.timer'] = {
      _note = 'The loop runs at 30 FPS and `dt` is capped at 0.1 s.',
      sleep = { 'partial', 'Only gives the turn back inside a `love.thread`; otherwise returns at once.' },
    },

    ['love.audio'] = {
      newSource = { 'partial', 'WAV only: 16-bit PCM (mono or stereo) or mono IMA ADPCM. `x.ogg` loads the `x.wav` converted next to it. '
        .. 'No Decoder or queueable sources. Checked: a file that is not `.wav` or `.ogg`.' },
      play = { 'partial', 'Without arguments it resumes every paused Source (LÖVE 0.10 behaviour).' },
    },

    ['love.sound'] = {
      newSoundData = { 'partial', 'From a WAV file name or WAV bytes; no empty SoundData, no Decoder.' },
    },

    ['love.joystick'] = {
      _note = 'The controller as LÖVE 11 shows an Xbox controller on PC (see `runtime/README.md`): up to 4, always gamepads.',
      loadGamepadMappings = { 'stub', 'The mapping is fixed.' },
      setGamepadMapping = { 'stub', 'The mapping is fixed; answers false.' },
      saveGamepadMappings = { 'partial', 'Returns the fixed mapping; writes no file.' },
    },

    ['love.keyboard'] = {
      _note = 'There is no keyboard and the controller is not turned into keys.',
      _default = { 'stub', 'No keyboard: nothing is ever down.' },
    },

    ['love.mouse'] = {
      _default = { 'stub', 'No mouse: the position is the centre of the screen and nothing is down.' },
    },

    ['love.touch'] = {
      getTouches = { 'stub', 'No touch screen: always an empty table.' },
    },

    ['love.event'] = {
      _note = 'The console has its own frame loop: there is no event queue and `love.run` is not used.',
      pump = { 'stub', 'Nothing to pump.' },
      poll = { 'stub', 'An iterator that ends at once.' },
      clear = { 'stub', 'Nothing to clear.' },
      quit = { 'partial', 'Leaves the game after `love.quit`. No exit status. Checked: `"restart"`.' },
      push = { 'partial', 'Only `"quit"`. Checked: another event.' },
    },

    ['love.math'] = {
      random = { 'partial', 'Lua\'s `math.random`: not LÖVE\'s generator, so not the same numbers as on PC for one seed.' },
    },

    ['love.system'] = {
      getOS = { 'partial', 'Answers `"Xbox 360"` (not a value LÖVE has).' },
      getProcessorCount = { 'partial', 'Always 6.' },
      openURL = { 'stub', 'Opens nothing.' },
      getClipboardText = { 'stub', 'Always `""`.' },
      setClipboardText = { 'stub', 'No clipboard.' },
    },

    ['love.window'] = {
      _note = SCREEN,
      setMode = { 'stub', SCREEN .. ' Answers true.' },
      updateMode = { 'stub', SCREEN .. ' Answers true.' },
      setFullscreen = { 'stub', SCREEN },
      setVSync = { 'stub', 'Always on.' },
      setIcon = { 'stub', 'No window icon.' },
      showMessageBox = { 'stub', 'Shows nothing and answers 1 (the first button).' },
      setTitle = { 'partial', 'Kept for `getTitle` only.' },
    },

    ['love.data'] = {
      compress = { 'stub', 'Returns the string unchanged.' },
      decompress = { 'stub', 'Returns the string unchanged: data compressed on PC cannot be read.' },
    },

    ['love.thread'] = {
      _note = 'There are no real threads: a thread is a coroutine on the main thread, resumed once per frame.',
      newThread = { 'partial', 'A coroutine on the main thread: it must give the turn back with `Channel:demand` or '
        .. '`love.timer.sleep`, or the game stops. Its code cannot `require("love.*")` modules of its own: it shares them.' },
    },
  },

  types = {
    Image = texture,
    Canvas = texture,
    Font = {
      _note = 'A font made from a TTF. Without one (`newFont(size)` and no `default_font` in game.lua) the font only '
        .. 'measures, roughly, and draws nothing.',
    },
    Text = {
      set = { 'partial', 'One line.' },
      setf = { 'partial', 'As `set`: the wrap limit and the alignment are ignored.' },
    },
    Shader = {
      send = { 'partial', 'Floats, vectors, matrices, arrays and up to 3 Images, as listed in the shader\'s metadata ([SHADERS.md](SHADERS.md)).' },
      sendColor = { 'partial', 'As `send`: no gamma conversion.' },
    },
    SpriteBatch = {
      _note = 'The buffer grows when it is full.',
      flush = { 'full' },
    },
    ParticleSystem = {
      _note = 'LÖVE 11\'s simulation, with its arguments, defaults and units; every emission area distribution is there.',
      setSizes = { 'partial', 'At most 8 sizes. Checked.' },
      setColors = { 'partial', 'At most 8 colours. Checked.' },
      setQuads = { 'partial', 'At most 64 quads; a Quad\'s viewport is read here, later changes are not seen. Checked: more quads.' },
    },
    Source = {
      setPitch = { 'partial', 'Up to 16.' },
      seek = { 'partial', 'Seconds only. Checked: `"samples"`.' },
      tell = { 'partial', 'Seconds only. Checked: `"samples"`.' },
      getDuration = { 'partial', 'Seconds only.' },
      resume = { 'partial', 'LÖVE 0.10 API (not in LÖVE 11: use `play`).' },
    },
    SoundData = {
      getBitDepth = { 'partial', 'Always 16.' },
    },
    Joystick = {},
    Thread = {
      release = { 'full' },
      wait = { 'stub', 'Returns at once: the thread only runs between frames.' },
    },
    Channel = {
      _note = 'At most 256 values per channel; more are dropped.',
      supply = { 'partial', 'Does not wait for the value to be taken.' },
      demand = { 'partial', 'No timeout. In a thread it waits one frame and may then answer nil; on the main thread it never waits.' },
    },
  },

  callbacks = {
    -- Every LÖVE 11 callback. The ones the console calls are found in the code.
    all = { 'conf', 'load', 'update', 'draw', 'quit', 'run', 'errorhandler', 'errhand', 'threaderror',
      'focus', 'mousefocus', 'visible', 'resize', 'displayrotated', 'lowmemory', 'directorydropped', 'filedropped',
      'keypressed', 'keyreleased', 'textinput', 'textedited',
      'mousepressed', 'mousereleased', 'mousemoved', 'wheelmoved',
      'touchpressed', 'touchreleased', 'touchmoved',
      'joystickadded', 'joystickremoved', 'joystickpressed', 'joystickreleased', 'joystickaxis', 'joystickhat',
      'gamepadpressed', 'gamepadreleased', 'gamepadaxis' },
    notes = {
      conf = 'Window and module settings are ignored, except `identity` and `window.title`.',
      update = '30 times a second; `dt` is capped at 0.1 s.',
      quit = 'After `love.event.quit`. Back held 3 s leaves without it.',
      threaderror = 'For an error in a `love.thread` coroutine.',
      joystickadded = 'The controllers connected at startup are added after `love.load`.',
      run = 'The console has its own frame loop: a custom `love.run` is not used.',
      errorhandler = 'An error is written to the log and the game stops.',
      errhand = 'An error is written to the log and the game stops.',
      keypressed = 'There is no keyboard and the controller is not turned into keys: use `gamepadpressed`.',
      keyreleased = 'There is no keyboard: use `gamepadreleased`.',
      textinput = 'There is no keyboard.',
      textedited = 'There is no keyboard.',
      mousepressed = 'There is no mouse.',
      mousereleased = 'There is no mouse.',
      mousemoved = 'There is no mouse.',
      wheelmoved = 'There is no mouse.',
      touchpressed = 'There is no touch screen.',
      touchreleased = 'There is no touch screen.',
      touchmoved = 'There is no touch screen.',
      focus = 'The game always has the focus.',
      mousefocus = 'There is no mouse.',
      visible = 'The game is always visible.',
      resize = SCREEN,
    },
  },

  -- LÖVE modules with no table at all in the console's love: any use is an error or "[missing]"
  absent_modules = {
    ['love.physics'] = 'No Box2D. Use a Lua library (bump.lua, HC...) or your own collisions.',
    ['love.image'] = 'No ImageData: no pixel access, no `newImageData`, no images made in code.',
    ['love.font'] = 'No Rasterizer or GlyphData; fonts come from `love.graphics.newFont`.',
    ['love.video'] = 'No video playback.',
  },

  -- What games commonly use and the console does not have: { name, hint }. The generator checks
  -- that each one really is absent. Not the whole of LÖVE: the rest is absent too.
  missing = {
    ['love'] = { { 'isVersionCompatible' }, { 'setDeprecationOutput' } },
    ['love.graphics'] = {
      { 'arc' }, { 'newMesh' }, { 'newImageFont' }, { 'newArrayImage' }, { 'stencil' }, { 'getScissor' },
      { 'intersectScissor' }, { 'getCanvas' }, { 'getShader' }, { 'getLineStyle' }, { 'setLineJoin' },
      { 'getDefaultFilter' }, { 'getPixelWidth' }, { 'getPixelHeight' }, { 'applyTransform' }, { 'replaceTransform' },
      { 'transformPoint' }, { 'inverseTransformPoint' }, { 'getStackDepth' }, { 'captureScreenshot' },
      { 'setWireframe' }, { 'getColorMask' }, { 'getSupported' }, { 'getSystemLimits' }, { 'getRendererInfo' },
      { 'getCanvasFormats' }, { 'isGammaCorrect' }, { 'discard' }, { 'flushBatch' }, { 'drawInstanced' },
      { 'drawLayer' }, { 'setDepthMode' }, { 'setMeshCullMode' }, { 'validateShader' },
    },
    Image = { { 'getFilter' }, { 'getWrap' }, { 'replacePixels' }, { 'getFormat' }, { 'isCompressed' }, { 'getMipmapCount' } },
    Canvas = { { 'renderTo', 'use `setCanvas`' }, { 'newImageData' }, { 'getFilter' }, { 'getWrap' }, { 'getFormat' },
      { 'getMSAA' }, { 'generateMipmaps' } },
    Font = { { 'getFilter' }, { 'getDPIScale' }, { 'getKerning' } },
    Text = { { 'add' }, { 'addf' }, { 'getFont' }, { 'setFont' } },
    Shader = { { 'getWarnings' } },
    SpriteBatch = { { 'addLayer' }, { 'setLayer' }, { 'attachAttribute' }, { 'setDrawRange' }, { 'getDrawRange' } },
    ParticleSystem = { { 'setAreaSpread', 'deprecated in LÖVE 11: use `setEmissionArea`' }, { 'getAreaSpread' } },
    ['love.filesystem'] = {
      { 'newFile' }, { 'lines' }, { 'newFileData' }, { 'mount' }, { 'unmount' }, { 'exists', 'LÖVE 0.10: use `getInfo`' },
      { 'isFile', 'LÖVE 0.10' }, { 'isDirectory', 'LÖVE 0.10' }, { 'getSize', 'LÖVE 0.10' },
      { 'getLastModified', 'LÖVE 0.10' }, { 'getRealDirectory' }, { 'getWorkingDirectory' }, { 'getUserDirectory' },
      { 'getAppdataDirectory' }, { 'setRequirePath' }, { 'getRequirePath' }, { 'setSymlinksEnabled' },
    },
    ['love.audio'] = {
      { 'setPosition' }, { 'setOrientation' }, { 'setVelocity' }, { 'setDistanceModel' }, { 'setEffect' },
      { 'newQueueableSource' }, { 'getSourceCount', 'use `getActiveSourceCount`' }, { 'getRecordingDevices' },
    },
    Source = {
      { 'setPosition' }, { 'setRelative' }, { 'setAttenuationDistances' }, { 'setRolloff' }, { 'setVolumeLimits' },
      { 'setFilter' }, { 'setEffect' }, { 'queue' }, { 'isPaused', 'LÖVE 0.10' }, { 'isStopped', 'LÖVE 0.10' },
      { 'type' }, { 'typeOf' },
    },
    ['love.sound'] = { { 'newDecoder' } },
    SoundData = { { 'getSample' }, { 'setSample' }, { 'getString' }, { 'getPointer' }, { 'getSize' } },
    ['love.timer'] = {},
    ['love.event'] = { { 'wait' } },
    ['love.math'] = {
      { 'setRandomSeed' }, { 'getRandomSeed' }, { 'randomNormal' }, { 'newRandomGenerator' }, { 'noise' },
      { 'newTransform' }, { 'newBezierCurve' }, { 'triangulate' }, { 'isConvex' }, { 'gammaToLinear' },
      { 'linearToGamma' }, { 'colorFromBytes' }, { 'colorToBytes' },
    },
    ['love.system'] = { { 'getPowerInfo' }, { 'vibrate' } },
    ['love.window'] = {
      { 'getPosition' }, { 'setPosition' }, { 'getSafeArea' }, { 'isVisible' }, { 'isMaximized' }, { 'maximize' },
      { 'minimize' }, { 'restore' }, { 'close' }, { 'requestAttention' }, { 'getIcon' }, { 'setDisplaySleepEnabled' },
    },
    ['love.data'] = { { 'encode' }, { 'decode' }, { 'hash' }, { 'pack' }, { 'unpack' }, { 'newByteData' }, { 'newDataView' } },
    ['love.thread'] = {},
    Thread = { { 'type' } },
    Channel = { { 'performAtomic' }, { 'hasRead' } },
    ['love.keyboard'] = { { 'isModifierActive' } },
    ['love.mouse'] = { { 'newCursor' }, { 'getRelativeMode' }, { 'isGrabbed' }, { 'setX' }, { 'setY' }, { 'isCursorSupported' } },
    ['love.joystick'] = {},
  },
}
