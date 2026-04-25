allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    
    // ── FIX: Automatically inject missing namespaces for older plugins ──
    afterEvaluate {
        if (project.plugins.hasPlugin("com.android.library") || 
            project.plugins.hasPlugin("com.android.application")) {
            val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            if (android != null && android.namespace == null) {
                // If it's tflite_flutter, set its specific namespace
                if (project.name == "tflite_flutter") {
                    android.namespace = "com.tfliteflutter.tflite_flutter"
                } else {
                    // Fallback: use a generic namespace based on the folder name
                    android.namespace = "com.example.${project.name.replace("-", "_")}"
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
