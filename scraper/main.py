from db import get_studios, delete_past_classes
from scraper import scrape_all

def run():
    print("Starting daily scrape...")
    delete_past_classes()
    studios = get_studios()
    print(f"Found {len(studios)} studios")
    scrape_all(studios)
    print("Done.")

if __name__ == "__main__":
    run()
