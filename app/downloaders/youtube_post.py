"""gallery-dl extractor for individual YouTube community posts."""

import json

from gallery_dl.extractor.common import Extractor, Message


class YoutubePostExtractor(Extractor):
    category = "youtube"
    subcategory = "post"
    root = "https://www.youtube.com"
    directory_fmt = ("{category}",)
    filename_fmt = "{post_id}_{num}.{extension}"
    archive_fmt = "{post_id}_{num}"
    pattern = r"(?:https?://)?(?:(?:www|m)\.)?youtube\.com/post/(?P<post_id>[A-Za-z0-9_-]+)"
    example = "https://www.youtube.com/post/Ugkx0123456789_-"

    def __init__(self, match):
        super().__init__(match)
        self.post_id = match.group("post_id")

    def items(self):
        response = self.request(f"{self.root}/post/{self.post_id}")
        post = self._find_post(self._initial_data(response.text))
        if not post:
            self.log.warning("Unable to find post %s", self.post_id)
            return

        images = list(self._values(post.get("backstageAttachment", {}), "backstageImageRenderer"))
        if not images:
            return

        title = self._runs_text(post.get("contentText"))
        author = self._runs_text(post.get("authorText"))
        metadata = {
            "post_id": self.post_id,
            "id": self.post_id,
            "title": title,
            "content": title,
            "author": {"name": author},
            "type": "image",
        }

        yield Message.Directory, "", metadata

        for num, image in enumerate(images, 1):
            thumbnails = image.get("image", {}).get("thumbnails", ())
            thumbnail = max(
                thumbnails,
                key=lambda item: item.get("width", 0) * item.get("height", 0),
                default=None,
            )
            if not thumbnail or not thumbnail.get("url"):
                continue

            image_url = self._original_image_url(thumbnail["url"])
            image_metadata = metadata.copy()
            image_metadata.update({
                "num": num,
                "extension": "",
                "url": image_url,
            })
            yield Message.Url, image_url, image_metadata

    def _initial_data(self, page):
        decoder = json.JSONDecoder()
        for marker in ("var ytInitialData = ", 'window["ytInitialData"] = '):
            start = page.find(marker)
            if start >= 0:
                return decoder.raw_decode(page, start + len(marker))[0]
        return {}

    def _find_post(self, data):
        return next((
            post for post in self._values(data, "backstagePostRenderer")
            if post.get("postId") == self.post_id
        ), None)

    @classmethod
    def _values(cls, value, key):
        if isinstance(value, dict):
            if key in value:
                yield value[key]
            for child in value.values():
                yield from cls._values(child, key)
        elif isinstance(value, list):
            for child in value:
                yield from cls._values(child, key)

    @staticmethod
    def _runs_text(value):
        return "".join(run.get("text", "") for run in (value or {}).get("runs", ()))

    @staticmethod
    def _original_image_url(url):
        if url.startswith("https://yt3.ggpht.com/") and "=" in url:
            return f"{url.split('=', 1)[0]}=s0?imgmax=0"
        return url
