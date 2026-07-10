from db import get_studios, delete_past_classes, delete_past_log_entries
from scraper import scrape_all

def run():
    print("Starting daily scrape...")
    delete_past_classes()
    delete_past_log_entries()
    studios = get_studios()
    print(f"Found {len(studios)} studios")
    scrape_all(studios)
    print("Done.")

if __name__ == "__main__":
    run()
