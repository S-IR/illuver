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

		if !strings.has_suffix(file.fullpath, ".glsl") do continue

		relPath, relErr := filepath.rel(inputDir, file.fullpath)
		if relErr != nil {
			log.fatalf("failed getting relative path %s: %v", file.fullpath, relErr)
		}

		dirOfRelativePath := filepath.dir(relPath)
		actualOutputPath, _ := filepath.join(
			{outputDir, dirOfRelativePath},
			context.temp_allocator,
		)
		isCompute := strings.contains(file.fullpath, ".comp.")

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
	name := strings.trim_suffix(filepath.base(path), ".glsl")


	when ODIN_DEBUG do debugLine :: "-gVS"
	stageString, ok := fmt.enum_value_to_string(stage)
	ensure(ok)

	os.make_directory_all(dir)
	cmd := make([dynamic]string)
	append(&cmd, "glslangValidator")
	when ODIN_DEBUG do append(&cmd, debugLine)
	if stage != .compute {


		stageAbbreviated := stage == .vertex ? "vert" : "frag"
		_, _ = append_elem(&cmd, "-S")
		_, _ = append_elem(&cmd, stageAbbreviated)

	}
	_, _ = append_elem(&cmd, "--target-env")
	_, _ = append_elem(&cmd, "vulkan1.3")
	if stage != .compute {
		define := strings.to_upper(stageString)
		_, _ = append_elem(&cmd, fmt.tprintf("-D%s", define))

	}
	_, _ = append_elem(&cmd, "-o")


	if stage == .compute {
		name, _ = strings.replace_all(name, ".comp", "")
	}
	outputPath, _ := filepath.join(
		{dir, strings.join({name, stageString, ext}, ".")},
		context.temp_allocator,
	)
	_, _ = append_elem(&cmd, outputPath)
	_, _ = append_elem(&cmd, path)
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
