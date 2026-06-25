"""Custom django-storages S3 backends for the Tethys portal.

Tethys seeds site settings (favicon, logo, placeholders) and renders templates with
leading-slash static paths like ``/tethys_portal/images/default_favicon.png``. The stock
django-storages ``S3Storage`` rejects any name with a leading ``/`` as a
``SuspiciousOperation`` (see ``_normalize_name``), which 500s every page that references one.

``PortalStaticS3Storage`` strips the leading slash before delegating, so those paths resolve
to the normal ``<location>/tethys_portal/images/...`` key (served via CloudFront) instead of
blowing up. Used as the ``staticfiles`` backend (set in portal-config.sh).
"""

from storages.backends.s3 import S3Storage


class PortalStaticS3Storage(S3Storage):
    def url(self, name, *args, **kwargs):
        if isinstance(name, str):
            name = name.lstrip("/")
        return super().url(name, *args, **kwargs)
