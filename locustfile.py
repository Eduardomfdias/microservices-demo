from locust import HttpUser, task, between
import random

PRODUCT_IDS = [
    "OLJCESPC7Z", "66VCHSJNUP", "1YMWWN1N4O",
    "L9ECAV7KIM", "2ZYFJ3GM2N", "0PUK6V6EV0",
    "LS4PSXUNUM", "9SIQT8TOJO", "6E92ZMYYFZ"
]

class OnlineBoutiqueUser(HttpUser):
    wait_time = between(0.5, 1)

    @task(10)
    def browse_product(self):
        pid = random.choice(PRODUCT_IDS)
        self.client.get(f"/product/{pid}", name="/product/[id]")

    @task(5)
    def index(self):
        self.client.get("/")

    @task(3)
    def add_to_cart(self):
        pid = random.choice(PRODUCT_IDS)
        self.client.post("/cart", data={"product_id": pid, "quantity": "1"}, name="/cart [add]")

    @task(2)
    def view_cart(self):
        self.client.get("/cart")

    @task(1)
    def checkout(self):
        # Garante que há algo no carrinho antes de fazer checkout
        pid = random.choice(PRODUCT_IDS)
        self.client.post("/cart", data={"product_id": pid, "quantity": "1"}, name="/cart [add]")
        self.client.post("/cart/checkout", data={
            "email": "test@asid.uc.pt",
            "street_address": "123 Main St",
            "zip_code": "10001",
            "city": "New York",
            "state": "NY",
            "country": "United States",
            "credit_card_number": "4432801561520454",
            "credit_card_expiration_month": "1",
            "credit_card_expiration_year": "2030",
            "credit_card_cvv": "672"
        }, name="/cart/checkout")

    @task(2)
    def set_currency(self):
        currency = random.choice(["EUR", "USD", "GBP", "JPY"])
        self.client.post("/setCurrency", data={"currency_code": currency})
