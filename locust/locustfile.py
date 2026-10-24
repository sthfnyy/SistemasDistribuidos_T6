import random
import string
import os
from typing import Dict, List

import gevent
from locust import between, events, task
from locust import HttpUser

from profiles import READ_PROFILE, WRITE_PROFILE


BASE_PATHS = {
    "owners": "/api/customer/owners",
    "vets": "/api/vet/vets",
}


@events.test_start.add_listener
def schedule_warmup_reset(environment, **_kwargs):
    """Reset cumulative Locust statistics after an optional warm-up period."""
    warmup_seconds = int(os.getenv("LOCUST_WARMUP_SECONDS", "0"))
    if warmup_seconds <= 0:
        return

    def reset_after_warmup():
        gevent.sleep(warmup_seconds)
        if environment.runner is not None:
            environment.runner.stats.reset_all()
            print(f"WARMUP_RESET_COMPLETED seconds={warmup_seconds}", flush=True)

    gevent.spawn(reset_after_warmup)


def _random_string(prefix: str, length: int = 8) -> str:
    return prefix + "-" + "".join(random.choices(string.ascii_lowercase + string.digits, k=length))


class PetClinicBaseUser(HttpUser):
    wait_time = between(0.5, 1.5)
    host = "http://localhost:8080"
    _known_owner_ids: List[int] = []

    def _load_known_owner_ids(self) -> None:
        if self._known_owner_ids:
            return
        try:
            response = self.client.get(BASE_PATHS["owners"], name="GET /api/customer/owners")
            response.raise_for_status()
            owners = response.json()
            self._known_owner_ids = [int(owner["id"]) for owner in owners if "id" in owner]
        except Exception:
            self._known_owner_ids = [1, 2, 3, 4, 5]

    def _next_owner_id(self) -> int:
        self._load_known_owner_ids()
        return random.choice(self._known_owner_ids)

    def _post_owner_payload(self) -> Dict[str, str]:
        unique = random.randint(1000, 999999)
        return {
            "firstName": _random_string("User", 5),
            "lastName": _random_string("Owner", 5),
            "address": f"Street {unique}",
            "city": "Sao Paulo",
            "telephone": str(1000000000 + unique),
        }

    @task(45)
    def list_owners(self):
        self.client.get(BASE_PATHS["owners"], name="GET /api/customer/owners")

    @task(35)
    def get_owner_by_id(self):
        owner_id = self._next_owner_id()
        self.client.get(f"{BASE_PATHS['owners']}/{owner_id}", name="GET /api/customer/owners/{id}")

    @task(15)
    def list_vets(self):
        self.client.get(BASE_PATHS["vets"], name="GET /api/vet/vets")

    @task(5)
    def create_owner(self):
        payload = self._post_owner_payload()
        self.client.post(BASE_PATHS["owners"], json=payload, name="POST /api/customer/owners")


class ReadProfile(PetClinicBaseUser):
    tasks = [
        (PetClinicBaseUser.list_owners, READ_PROFILE["GET /api/customer/owners"]),
        (PetClinicBaseUser.get_owner_by_id, READ_PROFILE["GET /api/customer/owners/{id}"]),
        (PetClinicBaseUser.list_vets, READ_PROFILE["GET /api/vet/vets"]),
        (PetClinicBaseUser.create_owner, READ_PROFILE["POST /api/customer/owners"]),
    ]


class WriteProfile(PetClinicBaseUser):
    tasks = [
        (PetClinicBaseUser.list_owners, WRITE_PROFILE["GET /api/customer/owners"]),
        (PetClinicBaseUser.get_owner_by_id, WRITE_PROFILE["GET /api/customer/owners/{id}"]),
        (PetClinicBaseUser.list_vets, WRITE_PROFILE["GET /api/vet/vets"]),
        (PetClinicBaseUser.create_owner, WRITE_PROFILE["POST /api/customer/owners"]),
    ]
