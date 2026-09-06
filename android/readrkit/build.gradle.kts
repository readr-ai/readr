// Android library module that compiles ReadrKit (the Swift package at the
// repo root) plus the thin `ReadrAndroid` facade for Android, generates the
// Java bindings with swift-java's jextract (JNI mode), and packages the Swift
// runtime into jniLibs. Everything the app needs from the kit comes through
// the generated `com.readrai.readr.kit` package.
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
    api("org.swift.swiftkit:swiftkit-core:+")
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

data class Abi(val android: String, val triple: String, val swiftLibDir: String, val ndkDir: String)
val minSdk = android.defaultConfig.minSdk!!
val allAbis = listOf(
    Abi("arm64-v8a", "aarch64-unknown-linux-android$minSdk", "swift-aarch64", "aarch64-linux-android"),
    Abi("x86_64", "x86_64-unknown-linux-android$minSdk", "swift-x86_64", "x86_64-linux-android"),
)
// Debug builds default to the host emulator's ABI plus arm64; override with
// READR_ANDROID_ABIS=arm64-v8a,x86_64.
val abis: List<Abi> = (System.getenv("READR_ANDROID_ABIS")?.split(',')?.map { it.trim() })
    ?.let { wanted -> allAbis.filter { it.android in wanted } }
    ?: allAbis

// Swift runtime libraries the facade links. ReadrKit uses FoundationXML (EPUB)
// and FoundationNetworking (HTTP), which the swift-android examples omit.
val swiftRuntimeLibs = listOf(
    "swiftCore", "swift_Concurrency", "swift_StringProcessing", "swift_RegexParser",
    "swift_Builtin_float", "swift_math", "swiftAndroid", "dispatch", "BlocksRuntime",
    "swiftSwiftOnoneSupport", "swiftDispatch", "swiftSynchronization", "swiftObservation",
    "Foundation", "FoundationEssentials", "FoundationInternationalization", "_FoundationICU",
    "FoundationXML", "FoundationNetworking",
)

val generatedJavaDir = layout.projectDirectory.dir(".build/plugins/outputs/readrkit/ReadrAndroid/destination/JExtractSwiftPlugin/src/generated/java")
val generatedJniLibsDir = layout.buildDirectory.dir("generated/jniLibs")

// swift-java has not published its Java runtime yet; build and publish it to
// the local Maven repository from the resolved checkout (needs JDK 25+ on
// JAVA_HOME_25 or JAVA_HOME).
val publishSwiftKit = tasks.register("publishSwiftKit") {
    group = "build setup"
    description = "Publishes org.swift.swiftkit:swiftkit-core to the local Maven repository from the swift-java checkout."
    doLast {
        val project = layout.projectDirectory.asFile
        fun run(vararg command: String, env: Map<String, String> = emptyMap()) {
            val pb = ProcessBuilder(*command).directory(project).inheritIO()
            pb.environment().putAll(env)
            val code = pb.start().waitFor()
            if (code != 0) throw GradleException("${command.joinToString(" ")} failed ($code)")
        }
        run(swiftlyPath.absolutePath, "run", "swift", "package", "+$swiftVersion", "resolve")
        val checkout = File(project, ".build/checkouts/swift-java")
        val env = System.getenv("JAVA_HOME_25")?.let { mapOf("JAVA_HOME" to it) } ?: emptyMap()
        run(File(checkout, "gradlew").absolutePath, "--project-dir", checkout.absolutePath, ":SwiftKitCore:publishToMavenLocal", "--no-daemon", "-q", env = env)
    }
}

abis.forEach { abi ->
    tasks.register<Exec>("buildSwift${abi.android.replace("-", "").replaceFirstChar { it.uppercase() }}") {
        group = "build"
        description = "Cross-compiles ReadrKit + ReadrAndroid for ${abi.android}."
        inputs.file(layout.projectDirectory.file("Package.swift"))
        inputs.dir(layout.projectDirectory.dir("Sources"))
        inputs.dir(rootProject.layout.projectDirectory.dir("../Sources/ReadrKit"))
        outputs.dir(layout.projectDirectory.dir(".build/${abi.triple}/debug"))
        workingDir = layout.projectDirectory.asFile
        executable = swiftlyPath.absolutePath
        // --disable-sandbox: the jextract plugin shells out to Gradle and javac,
        // which SwiftPM's macOS plugin sandbox would otherwise block.
        args("run", "swift", "build", "+$swiftVersion", "--swift-sdk", abi.triple, "--build-system", "native", "--disable-sandbox")
    }
}

val buildSwiftAll = tasks.register("buildSwiftAll") {
    group = "build"
    dependsOn(abis.map { "buildSwift${it.android.replace("-", "").replaceFirstChar { c -> c.uppercase() }}" })
    outputs.dir(generatedJavaDir)
}

val copyJniLibs = tasks.register<Copy>("copyJniLibs") {
    dependsOn(buildSwiftAll)
    abis.forEach { abi ->
        from(layout.projectDirectory.dir(".build/${abi.triple}/debug")) { include("*.so"); into(abi.android) }
        from(File(swiftAndroidRoot, "ndk-sysroot/usr/lib/${abi.ndkDir}/libc++_shared.so")) { into(abi.android) }
        from(swiftRuntimeLibs.map { File(swiftAndroidRoot, "swift-resources/usr/lib/${abi.swiftLibDir}/android/lib$it.so") }) { into(abi.android) }
    }
    into(generatedJniLibsDir)
    doLast {
        abis.forEach { abi ->
            val dir = generatedJniLibsDir.get().dir(abi.android).asFile
            val missing = (swiftRuntimeLibs.map { "lib$it.so" } + "libReadrAndroid.so" + "libc++_shared.so").filter { !File(dir, it).exists() }
            if (missing.isNotEmpty()) throw GradleException("jniLibs for ${abi.android} missing: $missing")
        }
    }
}

android.sourceSets.getByName("main") {
    java.srcDir(buildSwiftAll)
    jniLibs.srcDir(generatedJniLibsDir)
}
tasks.named("preBuild") { dependsOn(copyJniLibs) }
