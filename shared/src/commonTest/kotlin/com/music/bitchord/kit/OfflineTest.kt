package com.music.bitchord.kit

import com.music.bitchord.data.innertube.decodeUrlComponent
import kotlin.test.Test
import kotlin.test.assertEquals

class OfflineTest {
    @Test
    fun decodesFormEncoding() {
        assertEquals("a b/c", decodeUrlComponent("a+b%2Fc"))
        assertEquals("é", decodeUrlComponent("%C3%A9"))
        assertEquals("100%", decodeUrlComponent("100%"))
        assertEquals("%zz", decodeUrlComponent("%zz"))
    }

    @Test
    fun resizesArtwork() {
        assertEquals(
            "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj",
            Artwork.sized("https://lh3.googleusercontent.com/abc=w120-h120-l90-rj", 1200),
        )
        assertEquals("https://yt3.ggpht.com/x=s800", Artwork.sized("https://yt3.ggpht.com/x=s88", 800))
        assertEquals("https://i.ytimg.com/vi/x/hqdefault.jpg", Artwork.sized("https://i.ytimg.com/vi/x/hqdefault.jpg", 800))
    }

    @Test
    fun classifiesBrowseIds() {
        assertEquals(ItemKind.ALBUM, MediaItem.kindOf("MPREb_abc", "Album • Artist"))
        assertEquals(ItemKind.SINGLE, MediaItem.kindOf("MPREb_abc", "Single • Artist"))
        assertEquals(ItemKind.ARTIST, MediaItem.kindOf("UCabc", ""))
        assertEquals(ItemKind.PLAYLIST, MediaItem.kindOf("VLPLabc", ""))
    }
}
