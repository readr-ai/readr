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
        // No instrumented test may hang the run. Compose's `waitForIdle` —
        // inside every `performClick`, `performScrollToNode`, `assertExists`
        // — waits on `Espresso.onIdle()`, which has no timeout of its own: a
        // main looper that never reports idle is a test that never returns,
        // and CI then sits until the job's 90-minute cap with nothing to show
        // for it (run 34167244349 spent 74 minutes that way). AndroidJUnit's
        // per-test timeout turns that into a named failure in three minutes.
        // The slowest honest test on CI's emulator is well under a minute.
        testInstrumentationRunnerArguments["timeout_msec"] = "180000"
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
    implementation(libs.mlkit.genai.prompt)
    debugImplementation(libs.androidx.ui.tooling)
    debugImplementation(libs.androidx.ui.test.manifest)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.ui.test.junit4)
}
