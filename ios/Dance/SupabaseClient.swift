import Supabase
import Foundation

let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://hxheiznyfqaxcgahgatp.supabase.co")!,
    supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh4aGVpem55ZnFheGNnYWhnYXRwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1MjcyMzYsImV4cCI6MjA5ODEwMzIzNn0.kaY4gJNbmAK62nNsUkqK4UAdNzI9Y-5_yumJSoBBFdc"
)

/// Matches `_DAYS_AHEAD` in scraper/scraper.py — the scraper never populates classes
/// past this many days out, so the app shouldn't query or advertise further than this.
let scheduleDaysAhead = 10
