-- globals
type GenericFunction<A..., R...> = (A...) -> R...
type GenericScript = LocalScript | ModuleScript
type AnyFunction = <A..., R...>(A...) -> R...
type AnyTable = { [any]: any }
type AnyArray = { any }
type BuiltIn = nil | string | number | boolean
type BooleanNumber = number -- 0 or 1, used where the executor returns a Lua number instead of a real boolean
type userdata = typeof(newproxy())

type Metamethods =
	"__index" |
	"__newindex" |
	"__call" |
	"__concat" |
	"__unm" |
	"__add" |
	"__sub" |
	"__mul" |
	"__div" |
	"__idiv" |
	"__mod" |
	"__pow" |
	"__tostring" |
	"__metatable" |
	"__eq" |
	"__lt" |
	"__le" |
	"__mode" |
	"__len" |
	"__iter" |
	"__namecall"





declare secure_call: any
declare protect_gui: any

declare http_request: typeof(request) -- alias for `request`
declare HttpPost: typeof(request) -- alias for `request`

declare getexecutorname: typeof(identifyexecutor) -- alias for `identifyexecutor`




type cache = {
		Checks whether `object` is present in the instance cache
		(i.e. whether Lua-side references to it are still tracked normally).

		@param object Instance
		@return boolean -- true if cached, false if the instance has been invalidated
	]=]
	iscached: (object: Instance) -> boolean,

		Removes `object` from the instance cache. Future references obtained
		through the API (e.g. `game:GetService(...)`) will return a fresh,
		un-cached userdata for the same instance, which is useful for hiding
		modifications from other scripts that hold the old reference.

		@param object Instance
	]=]
	invalidate: (object: Instance) -> (),

		Replaces every cached reference to `object` with `newObject`, so future
		lookups resolve to `newObject` instead.

		@param object Instance -- the instance currently in the cache
		@param newObject Instance -- the instance that should replace it
	]=]
	replace: (object: Instance, newObject: Instance) -> (),
}

declare cache: cache




	Returns true if the function currently executing is running because the
	executor itself called it (as opposed to being called by the game).
	Commonly used inside hooks to distinguish your own calls from the game's.

	@return boolean
]=]
declare function checkcaller(): boolean

	Creates an independent copy of `function_to_clone`. The clone behaves
	identically but is a distinct closure, so hooking the original does not
	affect the clone (and vice versa).

	@param function_to_clone GenericFunction
	@return GenericFunction -- the cloned function
]=]
declare function clonefunction<A..., R...>(
	function_to_clone: GenericFunction<A..., R...>
): GenericFunction<A..., R...>

	Returns a SHA384 (or executor-specific) hash of a function's bytecode.
	Two functions with identical bytecode return the same hash, which is
	useful for identifying a function without relying on its (possibly
	obfuscated) name.

	@param function_to_hash AnyFunction
	@return string -- hex-encoded hash
]=]
declare function getfunctionhash(
	function_to_hash: AnyFunction
): string

	Replaces `function_to_hook` with `hook` at the closure level: every future
	call to `function_to_hook` (from any script, including the game) invokes
	`hook` instead. Returns a new callable that still points at the original
	implementation, so you can call through to it from inside your hook.

	@param function_to_hook GenericFunction -- the function being replaced
	@param hook GenericFunction -- the function that will run in its place
	@return GenericFunction -- callable referencing the original, unhooked function
]=]
declare function hookfunction<A..., R...>(
	function_to_hook: GenericFunction<A..., R...>,
	hook: GenericFunction<A..., R...>
): GenericFunction<A..., R...>

	Hooks a metamethod (e.g. "__index", "__namecall") on a table or Instance's
	metatable, even if the metatable is protected/locked. Returns a callable
	referencing the original metamethod so it can still be invoked from your hook.

	@param object AnyTable | Instance -- the object whose metatable should be hooked
	@param metamethod_name string -- e.g. "__namecall", "__index"
	@param hook GenericFunction -- replacement metamethod
	@return GenericFunction -- callable referencing the original metamethod
]=]
declare function hookmetamethod<A..., R...>(
	object: AnyTable | Instance,
	metamethod_name: string,
	hook: GenericFunction<A..., R...>
): GenericFunction<A..., R...>

	Returns true if `func` is a C closure (implemented natively by the
	executor/engine) rather than compiled Lua bytecode.

	@param func AnyFunction
	@return boolean
]=]
declare function iscclosure(
	func: AnyFunction
): boolean

	Returns true if `func` originates from the executor itself (as opposed to
	the game or a loaded script).

	@param func AnyFunction
	@return boolean
]=]
declare function isexecutorclosure(
	func: AnyFunction
): boolean

	Returns true if `func` is an L closure, i.e. a normal function compiled
	from Lua source (the opposite of a C closure).

	@param func AnyFunction
	@return boolean
]=]
declare function islclosure(
	func: AnyFunction
): boolean

	Wraps `function_to_wrap` so it behaves like a C closure from the engine's
	point of view. Commonly used to make a Lua function pass `iscclosure`
	checks, avoid yield-across-metamethod errors, and be harder to detect as
	a hook.

	@param function_to_wrap GenericFunction
	@return GenericFunction -- the wrapped, C-closure-like function
]=]
declare function newcclosure<A..., R...>(
	function_to_wrap: GenericFunction<A..., R...>
): GenericFunction<A..., R...>

	Reverts a function previously replaced by `hookfunction` back to its
	original behavior. No-op if the function was never hooked.

	@param functionToRestore AnyFunction
]=]
declare function restorefunction(
	functionToRestore: AnyFunction
): ()

	Returns the method name used in the current `__namecall` metamethod call
	(e.g. "FireServer", "Destroy"). Only meaningful while inside a
	`__namecall` hook/context; errors or returns an empty string otherwise.

	@return string
]=]
declare function getnamecallmethod(): string

	Compiles `src` into a callable function without executing it, similar to
	standard Lua `loadstring`. On failure returns `nil` plus an error message.

	@param src string -- Lua source code to compile
	@param chunkname string? -- optional name used in error messages/tracebacks
	@return (A...) -> any | nil -- the compiled function, or nil on failure
	@return string? -- error message, present only on failure
]=]
declare function loadstring<A...>(
	src: string,
	chunkname: string?
): (((A...) -> any) | nil, string?)




declare function rconsoleclear(): ()

declare function rconsolecreate(): ()

declare function rconsoledestroy(): ()

	Blocks and waits for a line of user input typed into the console window,
	then returns it.

	@return string -- the line of input entered by the user
]=]
declare function rconsoleinput(): string

	Prints `text` to the executor's dedicated console window (separate from
	the in-game/output log).

	@param text string
]=]
declare function rconsoleprint(text: string): ()

	Sets the title/caption of the executor's dedicated console window.

	@param title string
]=]
declare function rconsolesettitle(title: string): ()




type CryptCipherMode =
	"CBC" |
	"ECB" |
	"CTR" |
	"CFB" |
	"OFB" |
	"GCM"

type CryptHashAlgorithm =
	"sha1" |
	"sha384" |
	"sha512" |
	"md5" |
	"sha256" |
	"sha3-224" |
	"sha3-256" |
	"sha3-512"

type crypt = {
		Decodes a base64-encoded string back into raw bytes.

		@param data string -- base64 text
		@return string -- decoded raw bytes
	]=]
	base64decode: (data: string) -> string,

		Encodes raw bytes as a base64 string.

		@param data string -- raw bytes
		@return string -- base64-encoded text
	]=]
	base64encode: (data: string) -> string,

		Encrypts `data` with `key` using the given cipher mode (defaults to an
		executor-chosen mode, commonly CBC). If `iv` is omitted, one is
		generated for you and returned alongside the ciphertext.

		@param data string -- plaintext to encrypt
		@param key string -- encryption key (typically base64-encoded)
		@param iv string? -- initialization vector; auto-generated if omitted
		@param mode CryptCipherMode? -- cipher mode, e.g. "CBC", "GCM"
		@return string -- ciphertext (typically base64-encoded)
		@return string -- the IV used, so it can be stored for decryption
	]=]
	encrypt: (
		data: string,
		key: string,
		iv: string?,
		mode: CryptCipherMode?
	) -> (string, string),

		Decrypts ciphertext previously produced by `crypt.encrypt`.

		@param data string -- ciphertext to decrypt
		@param key string -- the key used to encrypt it
		@param iv string -- the IV used to encrypt it
		@param mode CryptCipherMode -- the cipher mode used to encrypt it
		@return string -- decrypted plaintext
	]=]
	decrypt: (
		data: string,
		key: string,
		iv: string,
		mode: CryptCipherMode
	) -> string,

		Generates `size` cryptographically random bytes.

		@param size number -- number of bytes to generate
		@return string -- random byte string of length `size`
	]=]
	generatebytes: (size: number) -> string,

		Generates a random base64-encoded key suitable for use with
		`crypt.encrypt` / `crypt.decrypt`.

		@return string -- base64-encoded key
	]=]
	generatekey: () -> string,

		Hashes `data` using the specified algorithm.

		@param data string -- input bytes
		@param algorithm CryptHashAlgorithm -- e.g. "sha256", "md5"
		@return string -- hex-encoded digest
	]=]
	hash: (
		data: string,
		algorithm: CryptHashAlgorithm
	) -> string,
}

declare crypt: crypt

	Shorthand for `crypt.base64encode`.

	@param data string
	@return string
]=]
declare function base64encode(data: string): string

	Shorthand for `crypt.base64decode`.

	@param data string
	@return string
]=]
declare function base64decode(data: string): string

	Compresses `data` using LZ4.

	@param data string -- raw bytes to compress
	@return string -- compressed bytes
]=]
declare function lz4compress(data: string): string

	Decompresses LZ4-compressed data previously produced by `lz4compress`.

	@param data string -- compressed bytes
	@param size number? -- expected decompressed size, if known
	@return string -- decompressed bytes
]=]
declare function lz4decompress(data: string, size: number?): string




type DebugInfo = {
	source: string, -- chunk source string
	short_src: string, -- shortened/human-readable source name
	func: AnyFunction, -- reference to the function itself
	what: "Lua" | "C", -- whether it's an L closure or C closure
	currentline: number, -- line currently executing (-1 if unavailable)
	name: string, -- function name, if known
	nups: number, -- number of upvalues
	numparams: number, -- number of declared parameters
	is_vararg: BooleanNumber, -- 1 if the function accepts varargs, else 0
}

type debug = {
		Reads constant #`index` from a function's bytecode (or from the
		function at stack `level`).

		@param func_or_level AnyFunction | number
		@param index number -- 1-based constant index
		@return BuiltIn -- the constant's value
	]=]
	getconstant: (
		func_or_level: AnyFunction | number,
		index: number
	) -> BuiltIn,

		Returns every constant embedded in a function's bytecode.

		@param func_or_level AnyFunction | number
		@return { BuiltIn }
	]=]
	getconstants: (
		func_or_level: AnyFunction | number
	) -> { BuiltIn },

		Gets the prototype (nested function) #`index` defined inside a
		function. With `activated = true`, returns every currently-alive
		closure instantiated from that prototype instead of the raw prototype.

		@param func_or_level AnyFunction | number
		@param index number -- 1-based proto index
		@param activated boolean? -- true to get live closures instead of the raw prototype
		@return AnyFunction | { AnyFunction }
	]=]
	getproto:
		((func_or_level: AnyFunction | number, index: number, activated: true) -> { AnyFunction }) &
		((func_or_level: AnyFunction | number, index: number, activated: false?) -> AnyFunction),

		Returns every prototype (nested function) defined inside a function.

		@param func_or_level AnyFunction | number
		@return { AnyFunction }
	]=]
	getprotos: (
		func_or_level: AnyFunction | number
	) -> { AnyFunction },

		Reads the value at stack slot `index` of the function currently
		running at call-stack `level`.

		@param level number -- call stack level (1 = caller of getstack)
		@param index number? -- stack slot index; omit to get the whole stack as an array
		@return any | { any }
	]=]
	getstack: (
		level: number,
		index: number?
	) -> any | AnyArray,

		Reads upvalue #`index` of a function.

		@param func_or_level AnyFunction | number
		@param index number -- 1-based upvalue index
		@return any
	]=]
	getupvalue: (
		func_or_level: AnyFunction | number,
		index: number
	) -> any,

		Returns every upvalue captured by a function.

		@param func_or_level AnyFunction | number
		@return { any }? -- nil if the function has no upvalues
	]=]
	getupvalues: (
		func_or_level: AnyFunction | number
	) -> AnyArray?,

		Overwrites constant #`index` in a function's bytecode with `value`.

		@param func_or_level AnyFunction | number
		@param index number -- 1-based constant index
		@param value BuiltIn -- new constant value
	]=]
	setconstant: (
		func_or_level: AnyFunction | number,
		index: number,
		value: BuiltIn
	) -> (),

		Overwrites the value at stack slot `index` for the function running at
		call-stack `level`.

		@param level number -- call stack level
		@param index number -- stack slot index
		@param value any -- new value to write
	]=]
	setstack: (
		level: number,
		index: number,
		value: any
	) -> (),

		Overwrites upvalue #`index` of a function with `value`.

		@param func_or_level AnyFunction | number
		@param index number -- 1-based upvalue index
		@param value any -- new upvalue value
	]=]
	setupvalue: (
		func_or_level: AnyFunction | number,
		index: number,
		value: any
	) -> (),

		Returns debug metadata (source, current line, param count, etc.) for a
		function or a given call-stack level.

		@param func_or_level AnyFunction | number
		@return DebugInfo
	]=]
	getinfo: (
		func_or_level: AnyFunction | number
	) -> DebugInfo,
}

declare debug: debug & typeof(debug)




	Base class for all Drawing objects (Line, Text, Image, Circle, Square,
	Quad, Triangle). Drawing objects render directly to the screen, outside
	the normal GUI hierarchy.
]=]
declare class DrawingObject
	Visible: boolean
	ZIndex: number
	Transparency: number
	Color: Color3
	__OBJECT_EXISTS: boolean -- true until Remove/Destroy has been called

	function Remove(self): ()
	function Destroy(self): ()
end

declare class DrawingLine extends DrawingObject
	Thickness: number
	From: Vector2
	To: Vector2
end

declare class DrawingText extends DrawingObject
	Text: string
	Size: number
	Center: boolean
	Outline: boolean
	OutlineColor: Color3
	Position: Vector2
	TextBounds: Vector2 -- read-only: measured size of the rendered text
	Font: number
end

declare class DrawingImage extends DrawingObject
	Data: string
	Size: Vector2
	Position: Vector2
	Rounding: number
end

declare class DrawingCircle extends DrawingObject
	Thickness: number
	NumSides: number
	Radius: number
	Filled: boolean
	Position: Vector2
end

declare class DrawingSquare extends DrawingObject
	Thickness: number
	Size: Vector2
	Position: Vector2
	Filled: boolean
end

declare class DrawingQuad extends DrawingObject
	Thickness: number
	PointA: Vector2
	PointB: Vector2
	PointC: Vector2
	PointD: Vector2
	Filled: boolean
end

declare class DrawingTriangle extends DrawingObject
	Thickness: number
	PointA: Vector2
	PointB: Vector2
	PointC: Vector2
	Filled: boolean
end

type DrawingFonts = {
	UI: number,
	System: number,
	Plex: number,
	Monospace: number,
}

export type DrawingNewTypes =
	"Line" |
	"Text" |
	"Image" |
	"Circle" |
	"Square" |
	"Quad" |
	"Triangle"

	Constructs a new Drawing object of the given kind.

	@param kind "Line" | "Text" | "Image" | "Circle" | "Square" | "Quad" | "Triangle"
	@return DrawingObject -- concrete subtype matching `kind`
]=]
export type DrawingNewFunction =
	(("Line") -> DrawingLine) &
	(("Text") -> DrawingText) &
	(("Image") -> DrawingImage) &
	(("Circle") -> DrawingCircle) &
	(("Square") -> DrawingSquare) &
	(("Quad") -> DrawingQuad) &
	(("Triangle") -> DrawingTriangle)

export type Drawing = {
	Fonts: DrawingFonts, -- built-in font IDs usable with DrawingText.Font
	new: DrawingNewFunction,
}

declare Drawing: Drawing

declare function cleardrawcache(): ()

	Reads a raw property from a Drawing object by name, bypassing the
	object's normal Luau-level property access.

	@param drawing DrawingObject
	@param property string -- property name, e.g. "Position", "Color"
	@return any
]=]
declare function getrenderproperty(
	drawing: DrawingObject,
	property: string
): any

	Returns true if `object` is a valid, still-existing Drawing object.

	@param object any
	@return boolean
]=]
declare function isrenderobj(
	object: any
): boolean

	Writes a raw property on a Drawing object by name.

	@param drawing DrawingObject
	@param property string -- property name, e.g. "Position", "Color"
	@param value any -- new value for the property
]=]
declare function setrenderproperty(
	drawing: DrawingObject,
	property: string,
	value: any
): ()




type FunctionFilterOptions = {
	Name: string?, -- match by function name
	IgnoreExecutor: boolean?, -- exclude functions created by the executor itself
	Hash: string?, -- match by getfunctionhash() output
	Constants: AnyArray?, -- match functions containing these constants
	Upvalues: AnyArray?, -- match functions containing these upvalues
}

type TableFilterOptions = {
	Keys: AnyArray?, -- match tables containing these keys
	Values: AnyArray?, -- match tables containing these values
	KeyValuePairs: AnyTable?, -- match tables containing these exact key/value pairs
	Metatable: any?, -- match tables sharing this metatable
}

	Returns every reachable table/function/etc. tracked by the Lua garbage
	collector. By default only functions are included.

	@param include_tables boolean? -- pass true to also include tables in the result
	@return { any } -- list of GC objects (functions, or functions+tables if requested)
]=]
declare getgc:
	((include_tables: false?) -> AnyArray) &
	((include_tables: true) -> { any | AnyArray })

	Returns the executor's global environment table (`_G` equivalent scoped
	to executor-loaded scripts), shared across scripts run by the executor.

	@return typeof(_G)
]=]
declare function getgenv(): typeof(_G)

	Returns the Lua registry, an internal table used by the VM to keep
	references alive.

	@return { any }
]=]
declare function getreg(): AnyArray

	Returns the game's own global environment table, as opposed to the
	executor's (see `getgenv`).

	@return typeof(_G)
]=]
declare function getrenv(): typeof(_G)

	Gets the environment table of the function running at call-stack `level`.

	@param level number
	@return AnyTable
]=]
declare function getfenv(
	level: number
): AnyTable

	Gets the environment table associated with function `f`.

	@param f function
	@return AnyTable
]=]
declare function getfenv(
	f: function
): AnyTable

	Sets the environment table of function `f` to `env`.

	@param f function
	@param env AnyTable
	@return function -- `f`, for chaining
]=]
declare function setfenv(
	f: function,
	env: AnyTable
): function

	Searches the garbage collector for tables or functions matching the given
	filter options.

	@param filter_type "table" | "function" -- what kind of GC object to search for
	@param filter_options TableFilterOptions | FunctionFilterOptions -- matching criteria
	@param return_one boolean? -- true to return only the first match instead of all matches
	@return AnyTable | AnyFunction | { AnyTable } | { AnyFunction } | nil
]=]
declare filtergc:
	((filter_type: "table", filter_options: TableFilterOptions, return_one: true) -> AnyTable?) &
	((filter_type: "table", filter_options: TableFilterOptions, return_one: false?) -> { AnyTable }) &
	((filter_type: "function", filter_options: FunctionFilterOptions, return_one: true) -> AnyFunction?) &
	((filter_type: "function", filter_options: FunctionFilterOptions, return_one: false?) -> { AnyFunction })





	Appends `contents` to the end of the file at `path`, creating it if it
	does not already exist.

	@param path string
	@param contents string
]=]
declare function appendfile(path: string, contents: string): ()

	Deletes the file at `path`. No-op (or errors, depending on executor) if
	it doesn't exist.

	@param path string
]=]
declare function delfile(path: string): ()

	Recursively deletes the folder at `path` and everything inside it.

	@param path string
]=]
declare function delfolder(path: string): ()

	Registers a local file as a game asset and returns an `rbxasset://` (or
	similar) URI that can be assigned to Image/Sound/etc. properties.

	@param path string -- path to a local file (e.g. an image) to expose
	@return string -- content URI usable in Instance properties
]=]
declare function getcustomasset(path: string): string

	@param path string
	@return boolean -- true if `path` exists and is a file
]=]
declare function isfile(path: string): boolean

	@param path string
	@return boolean -- true if `path` exists and is a folder
]=]
declare function isfolder(path: string): boolean

	Lists the contents of a folder.

	@param path string
	@return { string } -- full paths of every entry inside `path`
]=]
declare function listfiles(path: string): { string }

	Compiles the Lua source in the file at `path` into a callable function,
	without executing it. On failure returns `nil` plus an error message.

	@param path string
	@return AnyFunction? -- the compiled function, or nil on failure
	@return string? -- error message, present only on failure
]=]
declare function loadfile(
	path: string
): (AnyFunction?, string?)

	Creates a folder at `path`, including any missing parent directories.

	@param path string
]=]
declare function makefolder(path: string): ()

	Reads and returns the entire contents of the file at `path`.

	@param path string
	@return string
]=]
declare function readfile(path: string): string

	Writes `data` to the file at `path`, overwriting any existing contents
	(creates the file if it doesn't exist).

	@param path string
	@param data string
]=]
declare function writefile(path: string, data: string): ()

	Executes the Lua source in the file at `path` immediately, in the current
	environment.

	@param path string
]=]
declare function dofile(path: string): ()




	@return boolean -- true if the Roblox window currently has OS input focus
]=]
declare function isrbxactive(): boolean

declare function mouse1click(): ()
declare function mouse1press(): ()
declare function mouse1release(): ()

declare function mouse2click(): ()
declare function mouse2press(): ()
declare function mouse2release(): ()

	Moves the mouse cursor to an absolute screen position.

	@param x number
	@param y number
]=]
declare function mousemoveabs(x: number, y: number): ()

	Moves the mouse cursor relative to its current position.

	@param x number
	@param y number
]=]
declare function mousemoverel(x: number, y: number): ()

	Simulates scrolling the mouse wheel.

	@param pixels number -- scroll amount; sign determines direction
]=]
declare function mousescroll(pixels: number): ()




	Returns a new reference ("clone") to the same underlying Instance,
	separate from the cache entry other scripts hold. Useful for holding an
	instance reference that survives `cache.invalidate`.

	@param object T & Instance
	@return T -- a fresh reference to the same instance
]=]
declare function cloneref<T>(
	object: T & Instance
): T

	Compares two Instance references for equality even if one has been
	cloned via `cloneref`, i.e. checks underlying identity rather than
	reference identity.

	@param object1 Instance
	@param object2 Instance
	@return boolean
]=]
declare function compareinstances(
	object1: Instance,
	object2: Instance
): boolean

	Fires a ClickDetector's server-side click event as if a player clicked it.

	@param object ClickDetector
	@param distance number? -- simulated distance from the detector; defaults to within MaxActivationDistance
	@param event ("MouseClick" | "MouseHoverEnter" | "MouseHoverLeave" | "RightMouseClick")? -- which event to fire; defaults to "MouseClick"
]=]
declare function fireclickdetector(
	object: ClickDetector,
	distance: number?,
	event: (
		"MouseClick" |
		"MouseHoverEnter" |
		"MouseHoverLeave" |
		"RightMouseClick"
	)?
): ()

	Fires a ProximityPrompt's server-side trigger event as if a player
	activated it.

	@param object ProximityPrompt
]=]
declare function fireproximityprompt(
	object: ProximityPrompt
): ()

	Fires the Touched/TouchEnded interest between two BaseParts as if they
	physically touched, without requiring real physics contact.

	@param part BasePart
	@param part2 BasePart
	@param toggle boolean | BooleanNumber -- true/1 to simulate touch start, false/0 to simulate touch end
]=]
declare function firetouchinterest(
	part: BasePart,
	part2: BasePart,
	toggle: boolean | BooleanNumber
): ()

	Retrieves the function bound to a callback-type property (e.g.
	`BindableFunction.OnInvoke`, `RemoteFunction.OnClientInvoke`), which is
	not normally readable through the property directly.

	@param object Instance
	@param property string -- the callback property's name
	@return AnyFunction
]=]
declare function getcallbackvalue(
	object: Instance,
	property: string
): AnyFunction

	Returns the executor's dedicated, hidden-from-game GUI container
	(commonly used instead of CoreGui/PlayerGui so injected GUIs stay hidden
	from anti-cheat/game scripts).

	@return Instance
]=]
declare function gethui(): Instance

	Returns every Instance that currently exists in the game, including ones
	not parented under `game` (e.g. temporarily orphaned instances).

	@return { Instance }
]=]
declare function getinstances(): { Instance }

	Returns every Instance parented under `nil` (i.e. removed from the
	DataModel but not yet garbage collected).

	@return { Instance }
]=]
declare function getnilinstances(): { Instance }

	Checks whether a property on an Instance is currently scriptable (i.e.
	readable/writable from Lua), as opposed to engine-restricted.

	@param object Instance
	@param property string
	@return boolean
]=]
declare function isscriptable(
	object: Instance,
	property: string
): boolean

	Sets the system clipboard content directly from engine-level data (as
	opposed to `setclipboard`, which is typically used for plain text).

	@param data string
	@return boolean -- true on success
]=]
declare function setrbxclipboard(
	data: string
): boolean




	Returns the raw metatable of `object`, bypassing the `__metatable` field
	that would normally block `getmetatable`.

	@param object any
	@return AnyTable? -- nil if the object has no metatable
]=]
declare function getrawmetatable(
	object: any
): AnyTable?

	@param table AnyTable
	@return boolean -- true if the table is read-only (frozen)
]=]
declare function isreadonly(
	table: AnyTable
): boolean

	Forcibly replaces `object`'s metatable, bypassing `__metatable`
	protection.

	@param object T
	@param metatable AnyTable
	@return T -- `object`, for chaining
]=]
declare function setrawmetatable<T>(
	object: T,
	metatable: AnyTable
): T

	Sets whether `table` is read-only (frozen). Can be used to freeze a
	table, or to unfreeze one that was previously frozen (including tables
	frozen by the engine itself).

	@param table AnyTable
	@param state boolean -- true to freeze, false to unfreeze
]=]
declare function setreadonly(
	table: AnyTable,
	state: boolean
): ()




type Request = {
	Url: string,
	Method: string, -- e.g. "GET", "POST"
	Body: string?,
	Headers: { [string]: any }?,
	Cookies: { [string]: any }?,
}

type Response = {
	Body: string,
	StatusCode: number,
	StatusMessage: string,
	Success: boolean, -- true if StatusCode indicates success
	Headers: { [string]: any },
}

type ExtraDataModel = {
	HttpGet: (
		self: typeof(game),
		url: string,
		synchronous: boolean?,
		httpRequestType: typeof(Enum.HttpRequestType)?,
		doNotAllowDiabolicalMode: boolean?
	) -> string,

	Players: Players,
}

	Identifies the current executor.

	@return string -- executor name
	@return string -- executor version
]=]
declare function identifyexecutor(): (string, string)

	Sends an HTTP request from outside the game's sandbox (bypassing
	Roblox's usual HttpService domain restrictions).

	@param options Request -- { Url, Method, Body?, Headers?, Cookies? }
	@return Response
]=]
declare function request(
	options: Request
): Response

	Sets the system clipboard to plain text.

	@param text string
]=]
declare function setclipboard(
	text: string
): ()

	Sets (and typically unlocks/overrides) the client's frame-rate cap.

	@param fps number -- target FPS; 0 or a negative value commonly means "uncapped"
]=]
declare function setfpscap(
	fps: number
): ()

	Queues Lua source to run automatically immediately after the next
	teleport completes, in the new place.

	@param code string -- Lua source to run after teleporting
]=]
declare function queue_on_teleport(
	code: string
): ()

	Shows a native OS message box.

	@param text string -- body text
	@param caption string -- window title
	@param flags number -- OS-specific MB_* flags controlling icon/buttons
	@return number -- the ID of the button the user clicked
]=]
declare function messagebox(
	text: string,
	caption: string,
	flags: number
): number

declare game: typeof(game) & ExtraDataModel




	Reads a property that is normally hidden/non-scriptable on an Instance.

	@param instance Instance
	@param property_name string
	@return any -- the property's value
	@return boolean -- whether the property was hidden (true) or already normally readable (false)
]=]
declare function gethiddenproperty(
	instance: Instance,
	property_name: string
): (any, boolean)

	Returns the identity/context level of the currently running thread
	(Roblox's internal security context number).

	@return number
]=]
declare function getthreadidentity(): number

	Writes a property that is normally hidden/non-scriptable on an Instance.

	@param instance Instance
	@param property_name string
	@param property_value any
	@return boolean -- true on success
]=]
declare function sethiddenproperty(
	instance: Instance,
	property_name: string,
	property_value: any
): boolean

	Sets whether a property on an Instance is scriptable, letting you expose
	(or hide) properties that are normally blocked from Lua access.

	@param object Instance
	@param property string
	@param state boolean -- true to make scriptable, false to lock it
	@return boolean? -- previous scriptable state, if known
]=]
declare function setscriptable(
	object: Instance,
	property: string,
	state: boolean
): boolean?

	Sets the identity/context level of the currently running thread.

	@param id number -- target identity/context level
]=]
declare function setthreadidentity(
	id: number
): ()




	Returns the script that called into the currently executing function,
	i.e. the script one level up the call stack.

	@return GenericScript? -- nil if the caller isn't a script (e.g. it's the executor itself)
]=]
declare function getcallingscript(): GenericScript?

	Returns every currently loaded ModuleScript.

	@param excludeCore boolean? -- true to skip Roblox CoreScripts' modules
	@return { ModuleScript }
]=]
declare function getloadedmodules(
	excludeCore: boolean?
): { ModuleScript }

	Returns every script (LocalScript/ModuleScript) currently running.

	@return { GenericScript }
]=]
declare function getrunningscripts(): { GenericScript }

	Returns the compiled Luau bytecode for a script, decompiled sufficiently
	to be re-loadable, or nil if it can't be retrieved (e.g. protected).

	@param script GenericScript
	@return string?
]=]
declare function getscriptbytecode(
	script: GenericScript
): string?

	Returns the actual function closure backing a script, i.e. the callable
	you could invoke to re-run the script's top-level code.

	@param script GenericScript
	@return AnyFunction?
]=]
declare function getscriptclosure(
	script: GenericScript
): AnyFunction?

	Returns a hash of a script's bytecode (see `getfunctionhash`), useful for
	identifying a script's contents without relying on its name.

	@param script GenericScript
	@return string?
]=]
declare function getscripthash(
	script: GenericScript
): string?

	Returns every script instance (LocalScript/ModuleScript) reachable in the
	game, whether currently running or not.

	@return { GenericScript }
]=]
declare function getscripts(): { GenericScript }

	Returns the environment table (globals) of a specific script.

	@param script GenericScript
	@return { [any]: any }
]=]
declare function getsenv(
	script: GenericScript
): { [any]: any }




	Represents a single connection to an RBXScriptSignal, with extra
	introspection/control not exposed by the normal RBXScriptConnection.
]=]
declare class Connection
	Enabled: boolean
	ForeignState: boolean -- true if this connection belongs to a different script/thread than the caller
	LuaConnection: boolean -- true if backed by Lua code rather than an engine-native connection
	Function: AnyFunction? -- the connected handler, if it's a Lua function
	Thread: thread? -- the coroutine the handler runs on, if applicable

	function Fire(self, ...: any): ()
	function Defer(self, ...: any): ()
	function Disconnect(self): ()
	function Disable(self): ()
	function Enable(self): ()
end

	Fires `signal` with the given arguments for every currently connected
	listener, without needing to actually trigger the underlying engine
	event.

	@param signal RBXScriptSignal
	@param ... any -- arguments passed to each connected handler
]=]
declare function firesignal<T...>(
	signal: RBXScriptSignal<T...>,
	...: T...
): ()

	Returns every current connection to `signal`, including ones made by
	other scripts, as `Connection` objects supporting Fire/Disable/etc.

	@param signal RBXScriptSignal
	@return { Connection }
]=]
declare function getconnections<T...>(
	signal: RBXScriptSignal<T...>
): { Connection }

	Fires `signal` as if it originated from a network replication event
	(server -> client or client -> server), rather than firing it locally.

	@param signal RBXScriptSignal
	@param ... any -- arguments to replicate through the signal
]=]
declare function replicatesignal<T...>(
	signal: RBXScriptSignal<T...>,
	...: T...
): ()




type WebSocketConnection = {
	OnMessage: RBXScriptSignal<string>, -- fires with each incoming text message
	OnClose: RBXScriptSignal<()>, -- fires when the connection closes

		Sends a text message over the connection.

		@param message string
	]=]
	Send: (
		self: WebSocketConnection,
		message: string
	) -> (),

	Close: (
		self: WebSocketConnection
	) -> (),
}

type WebSocket = {
		Opens a new WebSocket connection to `url` (ws:// or wss://).

		@param url string
		@return WebSocketConnection
	]=]
	connect: (
		url: string
	) -> WebSocketConnection,
}

declare WebSocket: WebSocket

