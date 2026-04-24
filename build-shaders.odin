package build

import "core:fmt"
import "core:log"
import os "core:os"
import "core:path/filepath"
import "core:strings"

SPIRV :: true
PRINT_COMMAND :: true

main :: proc() {
	inputDir, _ := filepath.join({"src", "glsl"}, context.temp_allocator)
	outputDir, _ := filepath.join({"./build", "shader-binaries"}, context.temp_allocator)

	cwd, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do log.panicf("error getting cwd %s", os.error_string(err))

	inputDir, _ = filepath.join({cwd, inputDir}, context.temp_allocator)
	outputDir, _ = filepath.join({cwd, outputDir}, context.temp_allocator)

	if !os.exists(outputDir) {
		if err := os.make_directory_all(outputDir); err != nil {
			panic(os.error_string(err))
		}
	}

	w := os.walker_create(inputDir)
	defer os.walker_destroy(&w)

	for file in os.walker_walk(&w) {
		if path, err := os.walker_error(&w); err != nil {
			fmt.eprintfln("failed walking %s: %s", path, err)
			continue
		}

		// Process .slang files instead of .glsl
		if !strings.has_suffix(file.fullpath, ".slang") do continue

		relPath, relErr := filepath.rel(inputDir, file.fullpath)
		if relErr != nil {
			log.fatalf("failed getting relative path %s: %v", file.fullpath, relErr)
		}

		dirOfRelativePath := filepath.dir(relPath)
		actualOutputPath, _ := filepath.join(
			{outputDir, dirOfRelativePath},
			context.temp_allocator,
		)

		// Detect compute shader by ".comp." in filename (legacy convention)
		isCompute := strings.contains(file.fullpath, ".comp.")
		isImported := strings.contains(file.fullpath, ".imported.")
		if isImported do continue

		if SPIRV {
			if isCompute {
				compile_shader(file.fullpath, actualOutputPath, "spv", .compute)
			} else {
				compile_shader(file.fullpath, actualOutputPath, "spv", .vertex)
				compile_shader(file.fullpath, actualOutputPath, "spv", .fragment)
			}
		}
	}
}

compile_shader :: proc(path, dir, ext: string, stage: enum {
		vertex,
		fragment,
		compute,
	}) {
	name := strings.trim_suffix(filepath.base(path), ".slang")

	// Entry point names (standardized)
	entryName: string
	switch stage {
	case .vertex:
		entryName = "vertexMain"
	case .fragment:
		entryName = "fragmentMain"
	case .compute:
		entryName = "main"
	}

	stageString, ok := fmt.enum_value_to_string(stage)
	ensure(ok)

	os.make_directory_all(dir)

	cmd := make([dynamic]string)
	defer delete(cmd)

	append(&cmd, "slangc")

	append(&cmd, "-target", "spirv")
	append(&cmd, "-entry", entryName)
	append(&cmd, "-stage", stageString)

	// Output path
	outputName: string
	if stage == .compute {
		// For compute shaders, remove ".comp" part if present
		outputName = strings.clone(name, context.temp_allocator)
		outputName, _ = strings.replace_all(outputName, ".comp", "")
	} else {
		outputName = name
	}
	outputPath, _ := filepath.join(
		{dir, strings.join({outputName, stageString, ext}, ".")},
		context.temp_allocator,
	)
	append(&cmd, "-I", filepath.dir(path))

	append(&cmd, "-o", outputPath)
	when ODIN_DEBUG {
		append(&cmd, "-g") // Include debug info
	} else {
		append(&cmd, "-O3") // Include debug info
	}
	append(&cmd, path)

	exec(cmd[:])
}

exec :: proc(command: []string) {
	if PRINT_COMMAND {
		fmt.printfln(strings.join(command, " "))
	}

	state, stdOut, stdErr, err := os.process_exec(
		os.Process_Desc{working_dir = ".", command = command},
		allocator = context.temp_allocator,
	)
	if err != nil {
		panic(fmt.tprintf("error executing command %v : %s", command, os.error_string(err)))
	}

	msg := fmt.tprintf("%s%s", string(stdOut), string(stdErr))
	if state.exit_code != 0 {
		panic(msg)
	}
	fmt.print(msg)
}
