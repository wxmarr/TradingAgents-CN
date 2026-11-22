"""Concurrent users must share the process-local synchronous MongoDB pool."""

import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from app.core import database


class SyncMongoPoolReuseTest(unittest.TestCase):
    def test_concurrent_first_use_creates_one_client(self):
        fake_db = object()
        with patch.object(database, "_sync_mongo_client", None), \
             patch.object(database, "_sync_mongo_db", None), \
             patch.object(database, "MongoClient") as factory, \
             patch.object(database, "_is_pymongo_client_closed", return_value=False):
            factory.return_value.__getitem__.return_value = fake_db
            with ThreadPoolExecutor(max_workers=16) as executor:
                results = list(executor.map(lambda _: database.get_mongo_db_sync(), range(100)))
            self.assertTrue(all(result is fake_db for result in results))
            factory.assert_called_once()


if __name__ == "__main__":
    unittest.main()
