"""Patch gallery-dl's TwitterTweetExtractor to read text from X's newer details payload."""

from gallery_dl.extractor.twitter import TwitterTweetExtractor


def _install():
    orig = getattr(TwitterTweetExtractor, "_tweets_single", None)
    if orig is None or getattr(orig, "_details_patched", False):
        return

    def _tweets_single(self, tweet_id):
        for tweet in orig(self, tweet_id):
            if "full_text" not in tweet and isinstance(tweet.get("details"), dict):
                if full_text := tweet["details"].get("full_text"):
                    tweet["full_text"] = full_text
                if (urls := tweet.get("url_entities")) and not tweet.get("entities", {}).get("urls"):
                    tweet.setdefault("entities", {})["urls"] = urls
            yield tweet

    _tweets_single._details_patched = True
    TwitterTweetExtractor._tweets_single = _tweets_single


_install()
