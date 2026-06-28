import schedule
import time
from db import get_studios
from scraper import scrape_all

def run():
    print("Starting daily scrape...")
    studios = get_studios()
    print(f"Found {len(studios)} studios")
    scrape_all(studios)
    print("Done.")

if __name__ == "__main__":
    run()
    schedule.every().day.at("06:00").do(run)
    while True:
        schedule.run_pending()
        time.sleep(60)
