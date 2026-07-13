"""Firebase Admin SDK initialization (bypasses security rules)."""

from __future__ import annotations

import firebase_admin
from firebase_admin import credentials, firestore, storage

from . import config

_app = None


def _ensure_app():
    global _app
    if _app is None:
        cred = credentials.Certificate(str(config.service_account_path()))
        _app = firebase_admin.initialize_app(
            cred,
            {
                "projectId": config.PROJECT_ID,
                "storageBucket": config.STORAGE_BUCKET,
            },
        )
    return _app


def db():
    _ensure_app()
    return firestore.client()


def bucket():
    _ensure_app()
    return storage.bucket()
