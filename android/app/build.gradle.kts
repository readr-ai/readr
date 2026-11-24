import java.io.File
import java.security.MessageDigest

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.readrai.readr"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.readrai.readr"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "com.readrai.readr.ReadrTestRunner"
        // Third-party AARs include 32-bit libraries. Package only ABIs for
        // which ReadrKit's Swift/JNI facade is actually built.
        ndk.abiFilters += (System.getenv("READR_ANDROID_ABIS") ?: "arm64-v8a,x86_64")
            .split(',').map { it.trim() }.filter { it.isNotEmpty() }
        // No instrumented test may hang the run. Compose's `waitForIdle` —
        // inside every `performClick`, `performScrollToNode`, `assertExists`
        // — waits on `Espresso.onIdle()`, which has no timeout of its own: a
        // main looper that never reports idle is a test that never returns,
        // and CI then sits until the job's 90-minute cap with nothing to show
        // for it (run 34167244349 spent 74 minutes that way). AndroidJUnit's
        // per-test timeout turns that into a named failure in three minutes.
        // The slowest honest test on CI's emulator is well under a minute.
        testInstrumentationRunnerArguments["timeout_msec"] = "180000"
        // Real-model download/audio proof is an explicit manual integration run.
        testInstrumentationRunnerArguments["notAnnotation"] = "com.readrai.readr.ModelDownloadTest"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    packaging {
        jniLibs { useLegacyPackaging = false }
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":readrkit"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.media3.session)
    implementation(libs.androidx.media3.common)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.coroutines.jdk8)
    // Gemini Nano, on the phone. Brings genai-common along (FeatureStatus,
    // StreamingCallback, GenAiException). It ships no native library of its
    // own — the model lives in AICore — so the jniLibs packaging above, and
    // the 16 KB page alignment the Swift runtime needs, are untouched.
    implementation(libs.mlkit.genai.prompt) {
        // Google's own telemetry, not the model. `genai-prompt` declares the
        // datatransport stack, and merging it put `ACCESS_NETWORK_STATE`, a
        // `TransportBackendDiscovery` service naming the CCT (Google logging)
        // backend, a `JobInfoSchedulerService` and an alarm receiver into
        // Readr's manifest — an upload path an app that promises "nothing
        // leaves the phone" should not be carrying, least of all silently in
        // a permission a reader can read.
        //
        // Readr registers no transport and logs no events, so nothing here is
        // ever called. Taking the backend away leaves the runtime with
        // nowhere to send to; taking the runtime with it is what actually
        // takes the permission and the three components off the manifest, and
        // ML Kit's own initialiser and `NanoModel.readiness()` are unmoved by
        // it (`NanoModelTest`, on an emulator, which is the only ML Kit path
        // CI can run).
        exclude(group = "com.google.android.datatransport", module = "transport-backend-cct")
        exclude(group = "com.google.android.datatransport", module = "transport-runtime")
    }
    debugImplementation(libs.androidx.ui.tooling)
    debugImplementation(libs.androidx.ui.test.manifest)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.ui.test.junit4)
}

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.2")
    // Bounded, traversal-safe extraction of the pinned upstream model bundle.
    implementation("org.apache.commons:commons-compress:1.28.0")
    // Tesseract has no telemetry dependency; scanned PDF OCR remains offline.
    implementation("cz.adaptech.tesseract4android:tesseract4android:4.9.0")
}
configurations.configureEach {
    exclude(group = "com.google.android.datatransport", module = "transport-backend-cct")
    exclude(group = "com.google.android.datatransport", module = "transport-runtime")
}

// Both local development and CI verify bundled pronunciation/OCR data and the
// two native inference dependencies before building an APK/AAB.
val inferenceArtifacts = providers.provider {
    configurations.getByName("debugRuntimeClasspath").incoming.artifactView {
        componentFilter { id ->
            id is org.gradle.api.artifacts.component.ModuleComponentIdentifier &&
                id.group in setOf("com.microsoft.onnxruntime", "cz.adaptech.tesseract4android")
        }
    }.files
}
val verifyLocalInference by tasks.registering {
    val expectedAssets = mapOf(
        "eng.traineddata" to "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2",
        "misaki-en_us-g2p.onnx" to "757759c3e3ccb0bf59c379b1671c9834a27543ceaefd6846850823633b9665a1",
        "misaki-en_us-g2p.json" to "8a8e3350713b0a00102425a5d5bd6b58b34854c74a3e8d837589f55212c51658",
    )
    val expectedLibraries = mapOf(
        "onnxruntime-android-1.23.2.aar" to "82048d1f462218adae4ba76477089ab0ba76093d84f733540066db1a8ba6b827",
        "tesseract4android-4.9.0.aar" to "bce5d6413a1a5ae3d7240033fbbc851ba3217d0a08d9769400e17a077f42cb2a",
    )
    inputs.files(expectedAssets.keys.map { layout.projectDirectory.file("src/main/assets/$it") })
    inputs.files(inferenceArtifacts)
    doLast {
        fun verify(file: File, expected: String) {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) } }
            check(digest.digest().joinToString("") { "%02x".format(it) } == expected) { "Local inference integrity check failed: ${file.name}" }
        }
        for ((name, hash) in expectedAssets) verify(layout.projectDirectory.file("src/main/assets/$name").asFile, hash)
        val libraries = inferenceArtifacts.get().files
        check(libraries.size == expectedLibraries.size) { "Unexpected local inference dependencies" }
        for (file in libraries) verify(file, expectedLibraries[file.name] ?: error("Unpinned local inference dependency"))
    }
}
tasks.named("preBuild") { dependsOn(verifyLocalInference) }
