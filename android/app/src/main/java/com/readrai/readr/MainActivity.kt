package com.readrai.readr

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.ui.library.LibraryScreen
import com.readrai.readr.ui.library.LibraryViewModel
import com.readrai.readr.ui.reader.ChapterScreen
import com.readrai.readr.ui.theme.ReadrTheme
import java.net.URLDecoder
import java.net.URLEncoder

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as ReadrApplication
        setContent { ReadrTheme { ReadrNavHost(app.library) } }
    }
}

@Composable
private fun ReadrNavHost(repository: LibraryRepository) {
    val nav = rememberNavController()
    NavHost(nav, startDestination = "library") {
        composable("library") {
            val model: LibraryViewModel = viewModel(factory = factory { LibraryViewModel(repository) })
            LibraryScreen(model) { book -> nav.navigate("book/${book.id}/${URLEncoder.encode(book.title, "UTF-8")}") }
        }
        composable("book/{id}/{title}") { entry ->
            val id = entry.arguments?.getString("id") ?: return@composable
            val title = URLDecoder.decode(entry.arguments?.getString("title") ?: "", "UTF-8")
            ChapterScreen(repository, id, title) { nav.popBackStack() }
        }
    }
}

private inline fun <reified T : ViewModel> factory(crossinline create: () -> T) = object : ViewModelProvider.Factory {
    override fun <U : ViewModel> create(modelClass: Class<U>): U = @Suppress("UNCHECKED_CAST") (create() as U)
}
