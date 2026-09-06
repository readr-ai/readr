// Android library module that compiles ReadrKit (the Swift package at the
// repo root) plus the thin `ReadrAndroid` facade for Android, generates the
// Java bindings with swift-java's jextract (JNI mode), and packages the Swift
// runtime into jniLibs — per build type, so release APKs get `-c release`
// Swift. Everything the app needs from the kit comes through the generated
// `com.readrai.readr.kit` package.
//
// Requirements (see android/README.md): swiftly with the open-source Swift
// toolchain, the Swift SDK for Android (matching version) installed via
// `swift sdk install`, and `org.swift.swiftkit:swiftkit-core` in the local
// Maven repository (`./gradlew :readrkit:publishSwiftKit`).
import java.io.File

plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.readrai.readr.kit"
    compileSdk = 36
    defaultConfig {
        minSdk = 28 // the Swift SDK for Android's floor
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // Must match the swift-java version pinned in Package.swift: the bindings
    // jextract generates and this runtime are one contract.
    api(libs.swiftkit.core)
}

// ---- Swift toolchain discovery ---------------------------------------------

val swiftVersion: String = System.getenv("SWIFT_VERSION")?.takeIf { it.isNotBlank() } ?: "6.3.3"

fun firstExisting(vararg paths: String): File? = paths.map(::File).firstOrNull { it.exists() }

val swiftlyPath: File = System.getenv("SWIFTLY_PATH")?.let(::File)
    ?: firstExisting(
        "${System.getProperty("user.home")}/.swiftly/bin/swiftly",
        "${System.getProperty("user.home")}/.local/share/swiftly/bin/swiftly",
        "/opt/homebrew/bin/swiftly",
        "/usr/local/bin/swiftly",
    ) ?: throw GradleException("swiftly not found; set SWIFTLY_PATH (see android/README.md)")

val swiftSdksDir: File = System.getenv("SWIFT_SDK_PATH")?.let(::File)
    ?: firstExisting(
        "${System.getProperty("user.home")}/Library/org.swift.swiftpm/swift-sdks",
        "${System.getProperty("user.home")}/.config/swiftpm/swift-sdks",
        "${System.getProperty("user.home")}/.swiftpm/swift-sdks",
    ) ?: throw GradleException("no Swift SDKs directory; install the Swift SDK for Android (see android/README.md)")

// The installed bundle is named after the exact release, e.g.
// swift-6.3.3-RELEASE_android.artifactbundle.
val swiftSdkBundle: File = (System.getenv("SWIFT_ANDROID_SDK_BUNDLE")?.let { File(swiftSdksDir, it) })
    ?: swiftSdksDir.listFiles()?.firstOrNull { it.name.startsWith("swift-$swiftVersion") && it.name.endsWith("_android.artifactbundle") }
    ?: throw GradleException("no swift-$swiftVersion*_android.artifactbundle under $swiftSdksDir")
val swiftAndroidRoot = File(swiftSdkBundle, "swift-android")

// The NDK the bundle was linked against (setup-android-sdk.sh symlinks
// ndk-sysroot into it); its llvm-readelf verifies packaged libraries.
val llvmReadelf: File? = File(swiftAndroidRoot, "ndk-sysroot").canonicalFile.parentFile?.let { File(it, "bin/llvm-readelf") }?.takeIf { it.exists() }

data class Abi(val android: String, val triple: String, val swiftLibDir: String, val ndkDir: String) {
    val taskSuffix: String get() = android.replace("-", "").replaceFirstChar { it.uppercase() }
}
val minSdk = android.defaultConfig.minSdk!!
val allAbis = listOf(
    Abi("arm64-v8a", "aarch64-unknown-linux-android$minSdk", "swift-aarch64", "aarch64-linux-android"),
    Abi("x86_64", "x86_64-unknown-linux-android$minSdk", "swift-x86_64", "x86_64-linux-android"),
)
// Override with READR_ANDROID_ABIS=arm64-v8a,x86_64 (an emulator-only build
// is READR_ANDROID_ABIS=x86_64); anything unrecognised is an error, never an
// APK with no Swift in it.
val abis: List<Abi> = System.getenv("READR_ANDROID_ABIS")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }?.let { wanted ->
    val known = allAbis.associateBy { it.android }
    wanted.map { known[it] ?: throw GradleException("READR_ANDROID_ABIS: unknown ABI '$it' (known: ${known.keys})") }
} ?: allAbis

// Swift runtime libraries the facade links. ReadrKit uses FoundationXML (EPUB)
// and FoundationNetworking (HTTP), which the swift-android examples omit. The
// list is checked against the binaries' DT_NEEDED entries at build time.
val swiftRuntimeLibs = listOf(
    "swiftCore", "swift_Concurrency", "swift_StringProcessing", "swift_RegexParser",
    "swift_Builtin_float", "swift_math", "swiftAndroid", "dispatch", "BlocksRuntime",
    "swiftSwiftOnoneSupport", "swiftDispatch", "swiftSynchronization",
    "Foundation", "FoundationEssentials", "FoundationInternationalization", "_FoundationICU",
    "FoundationXML", "FoundationNetworking",
)
// Provided by Android itself; never packaged.
val androidSystemLibs = setOf("libc.so", "libm.so", "libdl.so", "liblog.so", "libz.so", "libandroid.so")

val generatedJavaDir = layout.projectDirectory.dir(".build/plugins/outputs/readrkit/ReadrAndroid/destination/JExtractSwiftPlugin/src/generated/java")

fun runProcess(vararg command: String, dir: File, env: Map<String, String> = emptyMap()) {
    val pb = ProcessBuilder(*command).directory(dir).inheritIO()
    pb.environment().putAll(env)
    val code = pb.start().waitFor()
    if (code != 0) throw GradleException("${command.joinToString(" ")} failed ($code)")
}

// swift-java has not published its Java runtime yet; build and publish it to
// the local Maven repository from the resolved checkout (needs JDK 25+ on
// JAVA_HOME_25 or JAVA_HOME). On macOS this also neutralises the plugin's
// own Gradle step, which SwiftPM's plugin sandbox blocks (README).
tasks.register("publishSwiftKit") {
    group = "build setup"
    description = "Publishes org.swift.swiftkit:swiftkit-core to the local Maven repository from the swift-java checkout."
    doLast {
        val project = layout.projectDirectory.asFile
        runProcess(swiftlyPath.absolutePath, "run", "swift", "package", "+$swiftVersion", "resolve", dir = project)
        val checkout = File(project, ".build/checkouts/swift-java")
        val gradlew = File(checkout, "gradlew")
        val real = File(checkout, "gradlew.real")
        if (!real.exists()) gradlew.copyTo(real)
        real.setExecutable(true) // File.copyTo does not carry the mode bit over
        val env = System.getenv("JAVA_HOME_25")?.let { mapOf("JAVA_HOME" to it) } ?: emptyMap()
        runProcess(real.absolutePath, "--project-dir", checkout.absolutePath, ":SwiftKitCore:build", ":SwiftKitCore:publishToMavenLocal", "--no-daemon", "-q", dir = checkout, env = env)
        if (System.getProperty("os.name").lowercase().contains("mac")) {
            gradlew.setWritable(true)
            gradlew.writeText("#!/bin/sh\n# Installed by :readrkit:publishSwiftKit — SwiftKitCore is already built; SwiftPM's\n# macOS plugin sandbox blocks the Gradle step swift-java's plugin would run here.\nexit 0\n")
            gradlew.setExecutable(true)
        }
    }
}

/** Copies the Swift build products and runtime into a per-variant jniLibs tree and verifies every DT_NEEDED is satisfied. */
abstract class SwiftJniLibs : DefaultTask() {
    @get:Input abstract val abiNames: ListProperty<String>
    @get:InputFiles abstract val inputLibs: ConfigurableFileCollection
    @get:Internal abstract val sourcesByAbi: MapProperty<String, List<File>>
    @get:Internal abstract val readelf: Property<String>
    @get:Input abstract val systemLibs: SetProperty<String>
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copyAndVerify() {
        val out = outputDir.get().asFile
        out.deleteRecursively()
        sourcesByAbi.get().forEach { (abi, files) ->
            val dir = File(out, abi).apply { mkdirs() }
            files.forEach { f ->
                if (!f.exists()) throw GradleException("jniLibs for $abi: missing ${f.name} (${f.path})")
                f.copyTo(File(dir, f.name), overwrite = true)
            }
            verify(dir)
        }
    }

    private fun verify(dir: File) {
        val present = dir.listFiles()!!.map { it.name }.toSet()
        val readelfPath = readelf.orNull ?: return
        val pending = ArrayDeque(listOf("libReadrAndroid.so"))
        val seen = mutableSetOf<String>()
        while (pending.isNotEmpty()) {
            val name = pending.removeFirst()
            if (!seen.add(name)) continue
            val proc = ProcessBuilder(readelfPath, "-d", File(dir, name).path).redirectErrorStream(true).start()
            val needed = proc.inputStream.bufferedReader().readLines()
                .filter { it.contains("(NEEDED)") }
                .mapNotNull { Regex("\\[(.+?)\\]").find(it)?.groupValues?.get(1) }
            proc.waitFor()
            needed.forEach { dep ->
                if (dep in systemLibs.get()) return@forEach
                if (dep !in present) throw GradleException("${dir.name}: $name needs $dep, which is not packaged — add it to swiftRuntimeLibs")
                pending.add(dep)
            }
        }
    }
}

/** Copies the jextract-generated Java into a declared output directory so :app's compile sees it as a real task output. */
abstract class GeneratedJava : DefaultTask() {
    @get:InputDirectory abstract val source: DirectoryProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty
    @TaskAction fun copy() {
        val out = outputDir.get().asFile; out.deleteRecursively(); source.get().asFile.copyRecursively(out)
    }
}

androidComponents {
    onVariants { variant ->
        val configuration = if (variant.buildType == "release") "release" else "debug"
        val variantSuffix = variant.name.replaceFirstChar { it.uppercase() }

        val buildTasks = abis.map { abi ->
            tasks.register<Exec>("buildSwift${abi.taskSuffix}$variantSuffix") {
                group = "build"
                description = "Cross-compiles ReadrKit + ReadrAndroid for ${abi.android} ($configuration)."
                inputs.file(layout.projectDirectory.file("Package.swift"))
                inputs.dir(layout.projectDirectory.dir("Sources"))
                inputs.dir(rootProject.layout.projectDirectory.dir("../Sources/ReadrKit"))
                inputs.property("swiftVersion", swiftVersion)
                inputs.property("configuration", configuration)
                outputs.file(layout.projectDirectory.file(".build/${abi.triple}/$configuration/libReadrAndroid.so"))
                outputs.file(layout.projectDirectory.file(".build/${abi.triple}/$configuration/libSwiftJava.so"))
                workingDir = layout.projectDirectory.asFile
                executable = swiftlyPath.absolutePath
                // --disable-sandbox: the jextract plugin shells out to javac and
                // Gradle, which SwiftPM's macOS plugin sandbox would otherwise block.
                args("run", "swift", "build", "+$swiftVersion", "--swift-sdk", abi.triple, "-c", configuration, "--build-system", "native", "--disable-sandbox")
            }
        }

        val generatedJava = tasks.register<GeneratedJava>("generatedJava$variantSuffix") {
            dependsOn(buildTasks)
            source.set(generatedJavaDir)
            outputDir.set(layout.buildDirectory.dir("generated/swiftJava/${variant.name}"))
        }
        variant.sources.java?.addGeneratedSourceDirectory(generatedJava, GeneratedJava::outputDir)

        val jniLibs = tasks.register<SwiftJniLibs>("swiftJniLibs$variantSuffix") {
            dependsOn(buildTasks)
            abiNames.set(abis.map { it.android })
            systemLibs.set(androidSystemLibs)
            readelf.set(llvmReadelf?.absolutePath)
            val map = abis.associate { abi ->
                val products = listOf("libReadrAndroid.so", "libSwiftJava.so").map { layout.projectDirectory.file(".build/${abi.triple}/$configuration/$it").asFile }
                val runtime = swiftRuntimeLibs.map { File(swiftAndroidRoot, "swift-resources/usr/lib/${abi.swiftLibDir}/android/lib$it.so") }
                val cxx = File(swiftAndroidRoot, "ndk-sysroot/usr/lib/${abi.ndkDir}/libc++_shared.so")
                abi.android to (products + runtime + cxx)
            }
            sourcesByAbi.set(map)
            inputLibs.from(map.values.flatten())
            outputDir.set(layout.buildDirectory.dir("generated/jniLibs/${variant.name}"))
        }
        variant.sources.jniLibs?.addGeneratedSourceDirectory(jniLibs, SwiftJniLibs::outputDir)
    }
}
