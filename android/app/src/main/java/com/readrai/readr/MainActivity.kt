package com.readrai.readr

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.readrai.readr.ui.library.LibraryScreen
import com.readrai.readr.ui.library.LibraryViewModel
import com.readrai.readr.ui.reader.ChapterScreen
import com.readrai.readr.ui.theme.ReadrTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as ReadrApplication
        setContent { ReadrTheme { ReadrNavHost(app) } }
    }
}

@Composable
private fun ReadrNavHost(app: ReadrApplication) {
    val nav = rememberNavController()
    NavHost(nav, startDestination = "library") {
        composable("library") {
            val model: LibraryViewModel = viewModel { LibraryViewModel(app) }
            LibraryScreen(model) { book -> nav.navigate("book/${book.id}") }
        }
        // The route carries only the id (a UUID, safe in a path); everything
        // else is looked up by id so the back stack never holds stale titles.
        composable("book/{id}") { entry ->
            val id = entry.arguments?.getString("id") ?: return@composable
            ChapterScreen(app, id) { nav.popBackStack() }
        }
    }
}
