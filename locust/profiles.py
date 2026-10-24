"""Profile definitions for the PetClinic load tests."""

READ_PROFILE = {
    "GET /api/customer/owners": 45,
    "GET /api/customer/owners/{id}": 35,
    "GET /api/vet/vets": 15,
    "POST /api/customer/owners": 5,
}

WRITE_PROFILE = {
    "GET /api/customer/owners": 20,
    "GET /api/customer/owners/{id}": 20,
    "GET /api/vet/vets": 20,
    "POST /api/customer/owners": 40,
}

PROFILE_LABELS = {
    "read": "ReadProfile",
    "write": "WriteProfile",
}
