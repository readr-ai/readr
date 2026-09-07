package com.readrai.readr

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import android.graphics.Color
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.readrai.readr.ui.library.LibraryScreen
import com.readrai.readr.ui.library.LibraryViewModel
import com.readrai.readr.ui.reader.ReaderScreen
import com.readrai.readr.ui.reader.ReaderViewModel
import com.readrai.readr.ui.settings.ProvidersScreen
import com.readrai.readr.ui.settings.ProvidersViewModel
import com.readrai.readr.ui.theme.Marginalia
import com.readrai.readr.ui.theme.ReadrTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as ReadrApplication
        setContent {
            val appearance by app.readerSettings.appearance.collectAsState()
            // The reading theme, not the system setting, decides the page colour,
            // so the system-bar icons must follow it too.
            LaunchedEffect(appearance.theme) {
                val bars = if (Marginalia.palette(appearance.theme).isDark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
            }
            ReadrTheme(appearance.theme) { ReadrNavHost(app) }
        }
    }
}

@Composable
private fun ReadrNavHost(app: ReadrApplication) {
    val nav = rememberNavController()
    NavHost(nav, startDestination = "library") {
        composable("library") {
            val model: LibraryViewModel = viewModel { LibraryViewModel(app) }
            LibraryScreen(
                model,
                onOpen = { book -> nav.navigate("book/${book.id}") },
                onSettings = { nav.navigate("settings") },
            )
        }
        composable("settings") {
            val model: ProvidersViewModel = viewModel { ProvidersViewModel { app.providers() } }
            ProvidersScreen(model) { nav.popBackStack() }
        }
        // The route carries only the id (a UUID, safe in a path); everything
        // else is looked up by id so the back stack never holds stale titles.
        composable("book/{id}") { entry ->
            val id = entry.arguments?.getString("id") ?: return@composable
            val model: ReaderViewModel = viewModel(key = "reader/$id") { ReaderViewModel({ app.library() }, id) }
            ReaderScreen(
                model,
                app.readerSettings,
                // Ask's empty state opens the provider screen; coming back
                // re-resolves the provider, so a key saved there works at once.
                onOpenProviders = { nav.navigate("settings") },
            ) { nav.popBackStack() }
        }
    }
}
