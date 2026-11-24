pluginManagement {
    repositories {
        mavenLocal()
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // swift-java's runtime (org.swift.swiftkit:swiftkit-core) is not on
        // Maven Central yet; `./gradlew :readrkit:publishSwiftKit` puts it in
        // the local repo. See android/README.md.
        mavenLocal()
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io"); content { includeGroup("cz.adaptech.tesseract4android") } }
    }
}
rootProject.name = "Readr"
include(":readrkit")
include(":app")
