const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    var target = b.standardTargetOptions(.{});
    // By default Zig sets the minimum macOS version to the SDK's own (very
    // recent) version, which would restrict the tool to the newest macOS.
    // When building for the native target, pin a broader floor (Ventura) that
    // covers both Apple Silicon and Intel. An explicit -Dtarget is respected.
    if (target.result.os.tag == .macos and target.query.isNative()) {
        target.query.os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
        target = b.resolveTargetQuery(target.query);
    }
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("run_pty_zig", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "run_pty_zig",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "run_pty_zig" is the name you will use in your source code to
                // import this module (e.g. `@import("run_pty_zig")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "run_pty_zig", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // In Zig 0.17, `test` blocks in an imported file are only compiled into a
    // test executable when the importing file actually references the imported
    // declarations inside a function or test body. To keep tests co-located with
    // their code (in args.zig, labels.zig, ...) while still having them run, we
    // make each test-bearing source file the root of its own test module.
    const args_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/args.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_args_tests = b.addRunArtifact(args_tests);

    const labels_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/labels.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_labels_tests = b.addRunArtifact(labels_tests);

    const ansi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ansi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ansi_tests = b.addRunArtifact(ansi_tests);

    const indicators_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indicators.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_indicators_tests = b.addRunArtifact(indicators_tests);

    const command_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/command.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_command_tests = b.addRunArtifact(command_tests);

    const render_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_render_tests = b.addRunArtifact(render_tests);

    const pty_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pty.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_pty_tests = b.addRunArtifact(pty_tests);

    const scanners_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scanners.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_scanners_tests = b.addRunArtifact(scanners_tests);

    const noninteractive_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/noninteractive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_noninteractive_tests = b.addRunArtifact(noninteractive_tests);

    const interactive_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interactive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_interactive_tests = b.addRunArtifact(interactive_tests);

    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_root_tests = b.addRunArtifact(root_tests);

    // Tests for the executable's root module (main.zig).
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the run steps do not depend on one another, they run in
    // parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_args_tests.step);
    test_step.dependOn(&run_labels_tests.step);
    test_step.dependOn(&run_ansi_tests.step);
    test_step.dependOn(&run_indicators_tests.step);
    test_step.dependOn(&run_command_tests.step);
    test_step.dependOn(&run_render_tests.step);
    test_step.dependOn(&run_pty_tests.step);
    test_step.dependOn(&run_scanners_tests.step);
    test_step.dependOn(&run_noninteractive_tests.step);
    test_step.dependOn(&run_interactive_tests.step);
    test_step.dependOn(&run_root_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
