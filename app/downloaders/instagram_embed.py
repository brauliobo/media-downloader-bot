"""gallery-dl extractor for public Instagram posts through their embed page, which needs no login."""

import json
import re

from gallery_dl import text
from gallery_dl.extractor.common import Extractor, Message


class InstagramEmbedExtractor(Extractor):
    category = "instagram"
    subcategory = "embed"
    root = "https://www.instagram.com"
    directory_fmt = ("{category}", "{user[name]}")
    filename_fmt = "{post_id}_{num}.{extension}"
    archive_fmt = "{post_id}_{num}"
    pattern = r"instagram-embed:(?P<post_id>[A-Za-z0-9_-]+)"
    example = "instagram-embed:CTAXxxODblP"

    CONTEXT = re.compile(r'"contextJSON":"((?:[^"\\]|\\.)*)"')

    def __init__(self, match):
        super().__init__(match)
        self.post_id = match.group("post_id")

    def _init(self):
        # a browser user agent gets the embed shell that loads the post with scripts; any other gets it rendered
        self.session.headers["User-Agent"] = "Mozilla/5.0"

    def items(self):
        media = self._media()
        if not media:
            self.log.warning("Unable to find post %s", self.post_id)
            return

        caption = next((edge["node"]["text"] for edge in media["edge_media_to_caption"]["edges"]), "")
        owner = media["owner"]
        metadata = {
            "post_id": self.post_id,
            "id": self.post_id,
            "content": caption,
            "user": {"name": owner["username"], "nick": owner.get("full_name") or owner["username"]},
        }
        yield Message.Directory, "", metadata

        children = [edge["node"] for edge in media.get("edge_sidecar_to_children", {}).get("edges", ())]
        for num, node in enumerate(children or [media], 1):
            url = node["video_url"] if node.get("is_video") else node["display_url"]
            item = {**metadata, "num": num, "type": "video" if node.get("is_video") else "image"}
            yield Message.Url, url, text.nameext_from_url(url, item)

    def _media(self):
        page = self.request(f"{self.root}/p/{self.post_id}/embed/captioned/").text
        context = self.CONTEXT.search(page)
        if not context:
            return None
        data = json.loads(json.loads(f'"{context.group(1)}"'))
        return (data.get("gql_data") or {}).get("shortcode_media")
