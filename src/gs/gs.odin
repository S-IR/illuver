package gs
import "core:os"
import "core:time"
import sdl "vendor:sdl3"
screenWidth: u32 = 1600
screenHeight: u32 = 900
quit: bool
seed: u64 = 123
// device: ^sdl.GPUDevice
window: ^sdl.Window

dt: f64
totalTime: f64 = 0
clearColor: [4]f32 = {0.02, 0.03, 0.08, 1}


nearPlane: f32 : 0.1
farPlane: f32 : 1600.0
NUM_CORES := -1
GameScreen :: enum {
	MainMenu,
	SpRealms,
	Loading,
	Game,
}
CurrGameScreen: GameScreen = .MainMenu

SIMULATION_TICK_RATE :: 60


LifeInterval :: time.Duration(1.75 * f64(time.Second))
WisdomInterval :: time.Duration(2.1 * f64(time.Second))
LightInterval :: time.Duration(2.3 * f64(time.Second))

LastLifeTick: time.Tick
LastWisdomTick: time.Tick
LastLightTick: time.Tick

WorldStartedAt: time.Time
GRAVITY :: f32(30.0)
