/** Career guide topics: player-hook description on list cards, sectioned walkthroughs on detail. relatedAppId links to a phone app when one exists. */
export const GUIDE_CATEGORIES = [
  { id: 'finance', label: 'Finance & economy' },
  { id: 'property', label: 'Property & garages' },
  { id: 'vehicles', label: 'Vehicles & trading' },
  { id: 'jobs', label: 'Jobs & hauling' },
  { id: 'racing', label: 'Racing & events' },
  { id: 'business', label: 'Business & progression' },
  { id: 'phone', label: 'Phone & tools' },
]

export const GUIDE_TOPICS = [
  {
    id: 'banking',
    category: 'finance',
    iconKey: 'bank',
    relatedAppId: 'bank',
    title: 'Banking',
    description: 'Career accounts · separate cash, business money, and transfers',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Bank" app on your phone. If you do not see it yet, install it from the "App Store" first.',
          'Review your existing accounts and balances on the main screen.',
          'Tap "+ New Account" if you want a separate place for personal money, business money, or savings.',
          'Use "⇄ Transfer" to move cash between accounts or pull money from an account when you need it.',
          'Tap an account to see its details, recent activity, and any pending transfers.',
        ],
      },
      {
        id: 'why-use-banks',
        title: 'Why use accounts',
        body: [
          'Bank accounts help you separate loose cash from money you are saving for a vehicle, property, or business.',
          'Some career systems can pull payments from bank accounts instead of only using cash on hand. Keeping the right funds in the right account makes loan payments, business expenses, and big purchases easier to plan.',
        ],
      },
      {
        id: 'transfers-and-waiting',
        title: 'Transfers and waiting',
        body: [
          'Transfers from business accounts can take a few minutes to finish. Check "Pending Transfers" on the "Bank" screen if money has not moved yet.',
          'You can cancel a pending transfer from the list if you changed your mind before it completes.',
        ],
      },
    ],
  },
  {
    id: 'loans',
    category: 'finance',
    iconKey: 'bank',
    relatedAppId: 'loans',
    title: 'Loans',
    description: 'Career borrowing · payments, credit, and mortgages',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Loans" app on your phone.',
          'Browse lenders and see which loan offers you qualify for.',
          'Check each offer for balance, interest rate, payment amount, and how often payments are due.',
          'Accept a loan when the terms fit your plan and you can cover the payments.',
          'Return to the "Loans" app anytime to track what you owe, upcoming payments, and your credit standing.',
        ],
      },
      {
        id: 'qualifying-and-credit',
        title: 'Qualifying and credit',
        body: [
          'Loan offers depend on the lender, your reputation with that organization, how much debt you already carry, and your credit score.',
          'Paying on time helps your credit and makes future borrowing easier. Missed payments can hurt your score, add interest, raise your rate, and shrink future offers.',
        ],
      },
      {
        id: 'paying-off-debt',
        title: 'Paying off debt',
        body: [
          'Payments are taken automatically when they are due, so keep enough money in the right account before the due date.',
          'If you get ahead, you can prepay part of a loan or pay the full remaining balance early to save on interest.',
          'Mortgages for property show up here too, so you can track home debt alongside regular loans in one place.',
        ],
      },
    ],
  },
  {
    id: 'market-watch',
    category: 'finance',
    iconKey: 'economy',
    relatedAppId: 'market-watch',
    title: 'Market Watch',
    description: 'Economy and market trends · timing buys, sales, and work',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Market Watch" app on your phone. It is preinstalled — no "App Store" download needed.',
          'Read the "Market Trends" charts for "Global Economy", "Job Market", "Housing", and "Vehicles".',
          'Scroll to "Latest News" for headlines about shifting pay and prices. The feed may be empty early in a career — reopen the app later to refresh.',
          'Before a big purchase or sale, open "Market Watch" again and compare trends to last time you looked.',
        ],
      },
      {
        id: 'what-each-market-means',
        title: 'What each market means',
        body: [
          '"Global Economy" affects many everyday costs — fuel, insurance, loans, quick travel, painting, recovery, and business purchases. A rising global index usually means higher costs; a falling one can ease pressure on your wallet.',
          '"Job Market" affects job and race payouts. "Housing" affects property buy, sell, and rent prices. "Vehicles" affects vehicle buy and sell values at dealers, on the marketplace, and in your garage inventory.',
          'Each market moves on its own. A weak global economy does not automatically mean cheaper cars or property — check the chart for the decision you are about to make.',
        ],
      },
      {
        id: 'using-it-for-decisions',
        title: 'Using it for decisions',
        body: [
          'Use "Market Watch" before buying property, listing a vehicle, taking on heavy debt, or stacking multiple big expenses at once.',
          'It will not tell you exactly what to do, but it helps you decide when to hold cash, when to buy, and when to push harder on jobs.',
        ],
      },
    ],
  },
  {
    id: 'real-estate',
    category: 'property',
    iconKey: 'building',
    relatedAppId: 'real-estate',
    title: 'Real Estate',
    description: 'Properties and garages · buy, rent, finance, and sell',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Real Estate" app on your phone. If the list is empty, that feature may not be available on your current map yet.',
          'Browse available properties, garages, and storage options near you.',
          'Tap a listing to see price, capacity, lease or purchase terms, and what you get for the money.',
          'Choose buy, rent, or claim when a starter option is offered and you are ready to commit.',
          'After you have a property, use the app to manage listings, review offers, or plan your next move.',
        ],
      },
      {
        id: 'buy-rent-or-finance',
        title: 'Buy, rent, or finance',
        body: [
          'Buying with cash costs more up front, but once owned the property is yours without recurring rent or mortgage payments.',
          'Renting gives temporary access without a big purchase. Fixed rentals have predictable payments; dynamic rentals can shift with the market; upfront rentals let you pay ahead for the lease.',
          'A mortgage lets you finance a property with scheduled payments instead of paying the full price at once. That helps you grow sooner, but missed payments create real debt pressure.',
        ],
      },
      {
        id: 'selling-and-offers',
        title: 'Selling and offers',
        body: [
          'Owned properties can be listed for sale when you want to move money out of real estate and back into vehicles or business plans.',
          'Review incoming offers on owned properties and accept or decline from the "Real Estate" app.',
          'Late rent or missed mortgage payments can lead to warnings or serious consequences, so treat property like any other bill.',
        ],
      },
    ],
  },
  {
    id: 'rentals',
    category: 'property',
    iconKey: 'building',
    relatedAppId: 'rentals',
    title: 'Rentals',
    description: 'Active leases · rent due, warnings, and ending a lease',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Rentals" app on your phone after you have signed at least one lease.',
          'If you have no active rentals, the app will tell you — you may need to rent through "Real Estate" first.',
          'Review each lease for rent amount, lease type, time remaining, and payments made so far.',
          'Check warning status before the due date so you are not caught off guard.',
          'Use the app to plan renewals, early endings, or moving vehicles before a lease expires.',
        ],
      },
      {
        id: 'why-rent',
        title: 'Why rent',
        body: [
          'Renting is useful when you need garage space before you can afford to buy, or when you want to test a location before committing to ownership.',
          'It is flexible, but you are still on the hook for payments on schedule.',
        ],
      },
      {
        id: 'late-payments-and-ending-early',
        title: 'Late payments and ending early',
        body: [
          'Late rent can escalate from a warning into eviction or lost access. Do not ignore warning messages.',
          'Ending a lease early may cost your deposit plus an extra fee, and vehicles stored there may be relocated.',
        ],
      },
    ],
  },
  {
    id: 'marketplace',
    category: 'vehicles',
    iconKey: 'car',
    title: 'Marketplace',
    description: 'Garage computer · dealers, private sellers, and your listings',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Use a garage computer and open "vehicle shopping".',
          'On the "Buy Vehicles" tab, pick a dealer or private seller from the list to browse what they have for sale.',
          'Open a listing to check price, condition, and fit before you purchase.',
          'To sell your own vehicle, switch to the "Sell Vehicles" tab, add a listing, and manage incoming offers there.',
        ],
        body: [
          'Phone shortcut: install the "Marketplace" app from the "App Store" if you want a quick option on the go. It is not the full experience — use the garage computer for dealers, reputation, and the complete buy and sell flow.',
          'On the phone, "Marketplace" shows a "private-listings" feed and a "Have one to sell?" link. From there you can browse NPC private sellers, list a vehicle, and accept, decline, or counter offers on your active listings.',
          'You cannot shop dealership inventory from the phone app. Dealer stock, org reputation, and taxi to lots are only on the garage computer "Buy Vehicles" tab.',
        ],
      },
      {
        id: 'listing-types',
        title: 'Listing types',
        body: [
          'Dealerships sell new and used stock tied to dealer organizations. Browse and buy from online dealers on the "Buy Vehicles" tab, or visit a lot in person.',
          'Private listings are used vehicles sold by NPC private sellers — each listing shows a seller name. Find them on the "Buy Vehicles" tab when you select a private seller.',
          'Personal listings are your own vehicles listed for sale — use the "Sell Vehicles" tab to post from your garage and receive offers you can accept or counter.',
        ],
      },
      {
        id: 'dealership-reputation',
        title: 'Dealer discovery and delivery',
        body: [
          'Physical dealerships appear on the shopping computer after you visit their lot once. Discovery is saved separately for each map.',
          'After discovery you can browse from home, but remote checkout and paid garage delivery unlock at dealer reputation level 2. Level 3 gives a 25% delivery discount.',
          'Factory and remanufacturing stores are always online. Early orders go to the map freight terminal; garage delivery unlocks with that individual seller at level 2.',
        ],
      },
      {
        id: 'market-watch-timing',
        title: 'Market Watch timing',
        body: [
          'Before listing a vehicle or buying on the garage computer, open "Market Watch" and check the "Vehicles" trend — buy and sell values follow that index, not the global economy alone.',
        ],
      },
    ],
  },
  {
    id: 'logistics',
    category: 'jobs',
    iconKey: 'box',
    relatedAppId: 'logistics',
    title: 'Logistics',
    description: 'Cargo and hauling · parcels, materials, vehicle moves, trailers at facilities',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Find a logistics facility on the map — warehouses, ports, and industrial sites that offer parcel, material, vehicle, or trailer work. The "Logistics" app can show what is available nearby and set a route before you drive over.',
          'At the facility, go to the "inspect spot" and choose "Inspect Cargo".',
          'On the delivery screen, browse parcels, materials, vehicle moves, or trailer hauls and assign work that fits your vehicle and equipment.',
          'Confirm your selections with "Continue", then use "Pick Up" at the facility parking area to load cargo or hook up a trailer.',
          'Drive to the destination facility, use "Drop Off" to finish the delivery, and collect your pay.',
        ],
      },
      {
        id: 'job-types',
        title: 'Job types',
        body: [
          'Parcel jobs are small cargo runs. Load packages into a vehicle with enough cargo space and deliver them on time.',
          'Material jobs move bulk goods and usually need the right tanker, dump body, dry bulk setup, or other compatible equipment.',
          'Vehicle delivery — sometimes called car jockey work — is about moving a vehicle safely rather than hauling loose cargo.',
          'Trailer work uses loaned or offered trailers from a facility. Hook up at the pickup spot, haul to the destination, and complete any return steps shown at the drop-off site.',
        ],
      },
    ],
  },
  {
    id: 'facility-work',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'facility-work',
    title: 'Facility Work',
    description: 'Forklift shifts · warehouse material moving',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Facility Work" app on your phone. If no facilities show up, this job type may not be available on your current map.',
          'Select a supported facility from the list.',
          'Tap "Start shift". A forklift will spawn for you.',
          'Use the forklift to move material props from the loading area into the marked drop zone.',
          'When a truck arrives, load the marked materials onto it from the pickup zone — finish your current batch first if one is still active. When the truck is full, open the "Facility Work" app and tap "Complete loading".',
          'Tap "End shift" when you are done for the session, or "Repair forklift" if the equipment is too damaged to keep working safely.',
        ],
      },
      {
        id: 'what-good-shifts-look-like',
        title: 'What good shifts look like',
        body: [
          'Facility Work is yard work: position the forklift, lift loads cleanly, stack or place materials, and finish batches without smashing the equipment.',
          'Some shifts include truck loading after materials are staged in a drop zone. The task list shows how many to load; tap "Complete loading" in the "Facility Work" app once the truck is full.',
          'Clean handling earns money and reputation more efficiently than rushing and breaking the forklift.',
        ],
      },
      {
        id: 'when-things-go-wrong',
        title: 'When things go wrong',
        body: [
          'Forklift damage can reduce your session pay. Slow down on tight turns and drops instead of slamming loads.',
          'If "Start shift" is greyed out or missing, the map may not support facility work yet — check back after moving to another location or when the app shows facilities again.',
        ],
      },
    ],
  },
  {
    id: 'beam-eats',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'beam-eats',
    title: 'BeamEats',
    description: 'Food delivery · shift offers, tips, rating, and streak pay',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "BeamEats" app on your phone while you are in a vehicle. If the app shows "Unavailable", BeamEats may not run on your current map or you may need to get back in a car.',
          'Tap "Start Shift" and wait for an incoming offer — orders come to you while you are on shift, not from a browse list.',
          'Review the restaurant, destination, base pay, distance, and expected time, then tap "Accept" or "Decline".',
          'Drive to the restaurant, stop near the pickup point, and wait a few seconds for the order to load — do not open logistics "Inspect Cargo" here; BeamEats pickup is automatic once you stop. Follow navigation to the customer, stop again, and wait to complete the drop-off.',
          'Check the earnings summary — base fare, tips, streak bonus, and logistics XP — then tap "Continue" for the next offer or "End Shift" when you are done.',
        ],
      },
      {
        id: 'earnings-and-rating',
        title: 'Earnings and rating',
        body: [
          'Your phone tracks "Rating", "Today\'s Earnings", and "Streak" while you work. Higher rating improves base pay on future orders.',
          'Tips reward smooth driving — rough bumps and harsh G-forces during delivery cut tips and can lower your rating. On-time delivery adds a small bonus; being late mainly reduces tips, not your base fare.',
          'The expected time on an offer is a guide, not a hard deadline — you still get paid base fare and streak bonus if you finish late. Rush only when it is safe; smooth driving usually beats speeding.',
          'Each completed order adds to your streak. Streaks pay a bonus on top of base fare and feed into logistics delivery XP shown on the summary screen.',
          'Logistics delivery skill level adds a pay bonus over time. Courier promotions — Bronze through Elite — unlock at higher logistics levels for extra pay and XP multipliers.',
        ],
      },
      {
        id: 'offers-radius-and-frequency',
        title: 'Offers, radius, and frequency',
        body: [
          'While on shift, new offers arrive on a timer. At low rating, expect a new offer roughly every 40–60 seconds. As your rating climbs toward 5.0, offers come much faster — down to about every 1–3 seconds at the top.',
          'Delivery distance grows with rating too. New drivers start with about 1 km max route length from restaurant to customer. Every 0.3 stars on your rating adds about 100 m to that cap, so higher-rated drivers can take longer, higher-paying runs.',
          'Incoming offers show distance and expected time before you accept — use those to decide whether a run fits your vehicle and route. A long expected time is fine to accept; you are not timed out if you arrive after it.',
        ],
      },
      {
        id: 'vehicles-and-driving',
        title: 'Vehicles and driving',
        body: [
          'Smaller, easy-to-drive vehicles work well for tight pickup spots and quick stops. You must come to a full stop at pickup and drop-off for the timer to complete.',
          'Nicer or higher-value vehicles can improve pay through the vehicle multiplier — but smooth handling matters more than speed for tips and rating.',
        ],
      },
    ],
  },
  {
    id: 'taxi',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'taxi',
    title: 'Taxi',
    description: 'Passenger fares · tips, ratings, and rider types',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Taxi" app on your phone. If the service is unavailable, taxi work may not be offered on your current map.',
          'Choose a vehicle with enough seats for the riders you want to attract.',
          'Tap "Drive Now" to go available for fares.',
          'Accept a rider when an offer appears, drive to pickup, then drop them off at the destination.',
          'Review base fare, tips, and your rating after each trip, then keep accepting fares or tap "Stop Driving" when you are done.',
        ],
      },
      {
        id: 'earnings-and-rating',
        title: 'Earnings and rating',
        body: [
          'Your phone shows rider type, passenger count, fare rate, driver rating, vehicle multiplier, and fare streak while you are working.',
          'Better vehicles can qualify for higher-value riders. Your driver rating helps you reach better clients over time.',
          'Fare streaks improve earnings while you keep accepting trips without long gaps.',
        ],
      },
      {
        id: 'rider-types-and-tips',
        title: 'Rider types & tips',
        body: [
          'Standard riders want speed and efficiency. Deliver quickly while avoiding rough driving — they mostly reward a "Speed Bonus".',
          'Commuters want punctual, steady driving. Arrive a little ahead of pace, keep comfort high, and avoid harsh G-forces for "On-Time Bonus" and "Comfort".',
          'Students are budget riders. Keep the route efficient and reasonably quick; they reward "Efficient Trip" more than luxury.',
          'Business riders are time-critical. Drive assertively and arrive fast, but do not stack too many aggressive events. They can pay "Efficiency Bonus" and "Assertive Driving".',
          'Executives expect quiet premium service. Keep the ride extremely smooth and controlled, avoid speeding, and aim for "White-Glove Service" or "Discreet Comfort".',
          'Luxury riders care about comfort over speed. Use a nicer vehicle, drive smooth and calm, and avoid aggressive inputs. "Immaculate Ride" and "Premium Comfort" are the big payouts.',
          'Tourists enjoy the journey. Take it slower, keep the ride scenic and smooth, and avoid rushing. "Scenic Bonus", "Perfect Pace", and "Wonderful Tour" reward that style.',
          'Families need seats and safety. Use a vehicle with enough capacity, drive slower, and keep the ride smooth for "Safe Driving" and "Smooth Ride".',
          'Party Groups need large-capacity vehicles and gentle driving. Avoid sudden movements, high G, and speeding. "Safety Bonus", "Gentle Driving", and "No Sudden Movements" are the goal.',
          'Thrill Seekers are the exception: they want speed and controlled excitement. Drive fast, create controlled G-force moments, but do not overdo it into chaos. "Speed Rush", "Adrenaline Bonus", and "Peak Thrill" pay out.',
        ],
      },
    ],
  },
  {
    id: 'repo',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'repo',
    title: 'Repo',
    description: 'Vehicle recovery · generate missions, haul targets, deliver to dealers',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Repo" app on your phone while you are in a vehicle. The minimap shows your area — there is no job list to browse.',
          'If you are on foot, the app shows "Need Vehicle" and repo is disabled. Get back in a car or truck first.',
          'Tap "Generate Mission" to roll a new recovery. The app briefly shows "Loading Mission..." while the target is placed.',
          'Follow navigation to the spawned vehicle shown in the panel ("Find and collect this vehicle"). Position your repo rig to load it — keep the truck nearby through the whole haul.',
          'If repo is unavailable, a "Repo Unavailable" overlay explains why — common causes are walking on foot, a challenge that disables repo pay, or a repo economy multiplier set to zero.',
        ],
      },
      {
        id: 'pickup-and-delivery',
        title: 'Pickup, haul, and delivery',
        steps: [
          'During pickup, bring your repo rig within about 20 m of the target vehicle. That starts the haul phase — load it onto your rollback bed, tiltdeck, or tow setup.',
          'Haul the target to the dealership named on screen ("Deliver to: …"). Stay in your repo rig; the panel tracks distance to the drop-off.',
          'Position the target within about 3 m of the dealership marker at low speed to finish — roll it off the bed or uncouple if you need to. Pay appears in the reward bubble and on the completion screen.',
          'Tap "Complete" on the completion overlay to collect and clear the mission. Use the X on the mission panel to abandon an active job.',
          'Stay close during each phase: during pickup, keep your repo rig within about 100 m of the target; during the haul, keep the target within about 100 m of your repo rig. Wander farther and a 10-second return countdown starts — let it expire and the job fails.',
        ],
      },
      {
        id: 'pay-tiers-and-skill',
        title: 'Pay, tiers, and Repo skill',
        body: [
          'The reward bubble at the top of the app estimates payout while you work. Final pay depends on the vehicle value, route distance, time, job tier, Repo skill bonus, and any active economy multipliers.',
          'Each mission rolls a tier chip such as "Joe\'s Junk Repo", "Budget Repo", "Standard Repo", "Luxury Repo", "Exotic Repo", or "Heavy Repo". Higher tiers pay more but unlock as your Repo skill level rises.',
          'Repo skill XP is awarded on completion. Each level above 1 adds +2% payout — the mission panel shows this as "Repo Lv N • +X%" when the bonus applies.',
          'Do not delete or despawn your repo rig mid-job. If it is removed, the mission ends immediately. Switching to a different vehicle before pickup starts regenerates a new mission.',
        ],
      },
      {
        id: 'equipment-plates-and-routing',
        title: 'Equipment, plates, and routing',
        body: [
          'Any vehicle can tap "Generate Mission", but a dedicated repo rig makes hauls much easier. Dealership "Repo Ready" configs — rollback pickups and tiltdeck trucks — come set up for recovery work.',
          'License plate text is not checked when you generate a mission, but a "repo" plate is strongly recommended on your recovery truck. Repo Ready vehicles ship with plate text "repo"; you can also set it later with "Personalize license plate" in your garage inventory when that option is available.',
          'Vehicles with a "repo" plate are treated as repo work trucks in traffic — they are not handled like undercover police during pursuit events, which helps avoid unwanted attention while you are loading or hauling.',
          'Scout the route before you commit. Tight lots, damage, and long backroads can turn a short map distance into a slow haul. Keep your repo rig parked where you can reach the target and the dealership without breaking the 100 m leash.',
        ],
      },
    ],
  },
  {
    id: 'quarry',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'quarry',
    title: 'Quarry',
    description: 'Loader contracts · rock and marble loading',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Quarry" app on your phone. If contracts are empty, quarry work may not be offered on your current map.',
          'Review available rock or marble contracts and what each one requires.',
          'Travel to the quarry loading zone shown for the contract.',
          'Use the front loader to move the required material into the target area or delivery point.',
          'Complete the weight or block count shown on the job before time runs out or the contract expires.',
        ],
      },
      {
        id: 'rock-vs-marble',
        title: 'Rock vs marble',
        body: [
          'Rock contracts use loose rock piles and usually track progress by weight. Steady bucket work beats rushed scoops that spill material.',
          'Marble contracts use blocks where supported. Handle blocks carefully — damaged blocks may not count toward the contract.',
        ],
      },
      {
        id: 'loader-control',
        title: 'Loader control',
        body: [
          'Line up the bucket or forks, keep the load stable, and avoid dropping or crushing the product.',
          'Quarry jobs pay best when you work steadily and keep material intact, not when you race and lose half the load.',
          'Different locations may offer different materials. If marble jobs never appear, your current map may only support rock work.',
        ],
      },
    ],
  },
  {
    id: 'fre-contracts',
    category: 'racing',
    iconKey: 'racing',
    relatedAppId: 'fre-contracts',
    title: 'FRE Contracts',
    description: 'Racing contracts · sponsors, goals, and commitments',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "FRE Contracts" app on your phone. If nothing is listed, FRE racing may not be active on your current map yet.',
          'Review open contracts, sponsors, and sanctioned race offers.',
          'Pick a contract whose objectives match the events and disciplines you can actually enter.',
          'Accept the contract and note deadlines, target results, and required vehicle types.',
          'Enter the listed races, track progress in the app, and collect rewards when objectives are met.',
        ],
      },
      {
        id: 'contracts-and-sponsors',
        title: 'Contracts and sponsors',
        body: [
          'Contracts ask you to finish specific races, hit target results, run certain disciplines, or use required vehicle types.',
          'Sponsors may expect valid event participation or discipline-specific performance. Keeping sponsor commitments supports longer-term motorsport income.',
        ],
      },
      {
        id: 'sanctioned-races',
        title: 'Sanctioned races',
        body: [
          'Sanctioned race offers let you commit to an upcoming race, navigate to it, or reschedule when needed.',
          'This loop is for FRE racing opportunities — not general delivery contracts or ordinary work orders.',
          'As your FRE discipline skills improve, more contract slots and harder offers can open up.',
          'Podium finishers undergo scrutineering at Parc Fermé. Exceeding class power-to-weight limits by more than 5% results in technical disqualification.',
        ],
      },
    ],
  },
  {
    id: 'freeroam-events',
    category: 'racing',
    iconKey: 'racing',
    relatedAppId: 'freeroam-events',
    title: 'Events',
    description: 'Freeroam competitions · races, challenges, and activities',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Events" app on your phone. If the list is empty, there may be no freeroam events on your current map right now.',
          'Browse upcoming activities — races, challenges, derby-style events, or special competitions.',
          'Tap an event to read entry requirements, vehicle rules, and rewards.',
          'Travel to the start point or follow the in-app navigation when you are ready to enter.',
          'Finish the event and check "Events" again for the next opportunity.',
        ],
      },
      {
        id: 'what-events-are-for',
        title: 'What events are for',
        body: [
          'Free Roam Events are activities outside normal job boards. They are a good way to test vehicles, earn rewards, and break up routine work.',
          'Some events require specific vehicles, entry modes, or performance levels — read details before you drive across town with the wrong build.',
        ],
      },
      {
        id: 'planning-ahead',
        title: 'Planning ahead',
        body: [
          'Pair "Events" with "FRE Contracts" when you are building a racing career. A contract may point you at events you would otherwise skip.',
          'If an event keeps rejecting your entry, check vehicle class, damage state, and whether you meet any skill or reputation requirement shown in the details.',
        ],
      },
    ],
  },
  {
    id: 'car-meet',
    category: 'racing',
    iconKey: 'car',
    relatedAppId: 'car-meet',
    title: 'Car Meet',
    description: 'Car meets · clubs, showcases, offers, and scene rep',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Car Meet" app on your phone. If invites are quiet, meets may not be scheduled on your current map yet.',
          'Read incoming invites and note the meet type before you RSVP.',
          'Drive a vehicle that fits the theme or club when one is required.',
          'Travel to the meet location and follow on-screen prompts to park, showcase, cruise, or walk the lot.',
          'Build car meet reputation over time by showing up with interesting vehicles and staying active in clubs that match your style.',
        ],
      },
      {
        id: 'meet-types',
        title: 'Meet types',
        body: [
          'Showcase meets focus on bringing a vehicle that fits the scene and building attention around it.',
          'Street cruise meets add a driving phase where the group moves instead of only parking up.',
          'Bazaar meets lean into selling — bring a vehicle and work incoming buyer offers before the event ends.',
          'Club meets tie to specific groups — brands, models, styles, or themes. Joining the right club helps you get invites that match what you like to build.',
        ],
      },
      {
        id: 'making-offers',
        title: 'Making offers on meet cars',
        body: [
          'While a meet is active, other vehicles spawn around the lot. They are not listed with a buy-now price — walk up on foot, inspect one you like, and tap "Make an Offer" to start negotiation.',
          'You can make offers at showcase, cruise, club, bazaar, and elite meets. The "Car Meet" app shows how many meet cars are nearby while the event is running.',
          'If your offer is accepted and you have garage space and funds, the purchase completes like a normal vehicle buy.',
          'Lowball offers hurt your standing. Offers below about 80% of the car\'s estimated market value reduce car meet reputation — you will see "Lowball offer hurt your car meet reputation." Stay closer to market if you want to negotiate without burning scene rep.',
        ],
      },
      {
        id: 'selling-and-rep',
        title: 'Selling your car and reputation',
        body: [
          'To sell at a meet, bring your vehicle during the showcase phase and park it at the lot. Your car is not listed with a buy-now price — meet buyers make offers to you, the same way you make offers on cars you want to buy.',
          'Offers can arrive while the event runs. Open "View Offers" or "Offers on Your Car" in the "Car Meet" app to accept, decline, or negotiate.',
          'The offers screen lets you optionally tune your asking expectation, which can influence what buyers offer — you do not need to set anything before offers start.',
          'Bazaar meets push selling harder: you are expected to move the car you brought, and ending without a sale can cost reputation.',
          'Your vehicles and attendance build car meet reputation over time through popularity and meet history — not just showing up once.',
          'Use meets to show off builds, find themed communities, scout cars to offer on, or sell with real foot traffic around your parked car.',
        ],
      },
    ],
  },
  {
    id: 'racing-team',
    category: 'racing',
    iconKey: 'racing',
    relatedAppId: 'racing-team',
    title: 'Racing Team',
    description: 'Team HQ career · leagues, goals, fleet, proxy races, and sponsors',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Racing Team is at Belasco Motorsports Paddock on West Coast USA. Buy the property from the business map, then use the Racing Computer upstairs — that is where you run the team.',
          'You start in League 1, Belasco City Racing Club. Open the "Goals" tab on the computer and work through goals one at a time; only the current goal is active.',
          'Early League 1 is solo: buy a team car on the "Vehicles" tab (team account, not personal cash), pull it out in the garage bay, and drive your own laps and races.',
          'Finish goal "Short Track Laps" — 5 consecutive Short Track laps — to unlock the sanctioned race board on the "Race" tab. Until then, "Available Races" stays empty.',
          'Complete every goal in a league to earn a league invite. Accept from the splash or later on "Goals" — registration is paid from the team account.',
        ],
      },
      {
        id: 'hq-computer-and-phone',
        title: 'HQ, computer, and phone',
        body: [
          'The paddock is the business: office computer upstairs, vehicle bay downstairs, team bank account, fleet garage, and sanctioned races tied to the facility.',
          'Computer tabs are "Home", "Goals", "Vehicles", "Inventory", "Race", "Drivers", and "Finances". Goals, skill trees, parts work, and full race booking live on the computer.',
          'The "Racing Team" phone app is optional — not the hub. Unlock it with the "Shop App" skill in Team Ops (after "Laptop"). Until then the app shows "Unlock skill to use this app".',
          'Phone tabs cover a subset: "Home" (scheduled races, sponsorship, finances widgets), "Races", "Drivers", and "Vehicles". Handy for a quick check or to spectate away from the desk; most management stays on the computer.',
          '"Laptop" adds a second Racing Computer in the vehicle bay. "Pit Fuel" lets you refuel fleet cars from the shop and bill the team account.',
        ],
      },
      {
        id: 'leagues-and-goals',
        title: 'Leagues and goals',
        body: [
          'Four leagues run in order: Belasco City Racing Club, then West Coast Amateur Racing Association (WCARA), Nodeoline Racing Series (NRS), and Beam Racing International (BRI).',
          'Each league is a chain of goals — buy cars, set lap times, earn money, win races, build class, hire drivers, hit team value targets, and more. Check "Goals" for the current target and progress.',
          'League 1 keeps you in the seat: no driver hires yet. Finishing League 1 unlocks the WCARA invite. League 2 adds drivers, proxy races, and sponsors.',
          'Later leagues ask for more drivers, stronger cars (Stock through Modified and Super), more race volume, and larger financial milestones. Completing all League 4 goals finishes the racing-team arc.',
        ],
      },
      {
        id: 'fleet-class-and-brackets',
        title: 'Fleet, class, and brackets',
        body: [
          'Fleet cars are bought on the "Vehicles" tab and stored in the paddock garage. Factory configs only; purchases debit the team account.',
          'Sanctioned class follows effective power-to-weight: Stock, Modified, Super, and Open. Installed parts matter — a factory build can stay Stock even if raw numbers look higher.',
          'Race offers on the board use hp/kg brackets (for example Modified club low or mid). Your car must fit the bracket; overpowered builds are blocked.',
          'The board refreshes over time and rolls races that match your fleet plus aspirational classes above it. Keep cars in repair — heavy damage can lock a fleet car out of use.',
          'The "Dyno" skill lets you test vehicles on your workshop dyno to earn official [Dyno Certified] badges. Stock cars race freely, but builds modified past a 5% margin require dyno certification before entering upper-tier sanctioned races.',
          'Podium finishers undergo scrutineering at Parc Fermé. Exceeding class bracket limits by more than 5% results in disqualification and a $350 fine deducted from team funds.',
          '"Garage Slots" (QOL skill) adds roster capacity and lets you pull more than one team car out at once, up to the physical bay size.',
        ],
      },
      {
        id: 'league-1-racing',
        title: 'League 1 racing',
        body: [
          'Before WCARA, you are the driver. Pick an offer from "Available Races", choose a fleet car, pay the entry fee from the team account, and go to the grid yourself.',
          'Sanctioned races pay into team finances and count toward goals. Entry fees scale with class and league tier.',
          'Goal races include lap challenges on Short Track and Track, podium targets, win counts, and pushing a car into Modified class. Read each goal on the "Goals" tab so you are working on the right activity.',
        ],
      },
      {
        id: 'proxy-races-and-drivers',
        title: 'Proxy races and drivers',
        body: [
          'From WCARA (League 2) onward you can hire drivers on the "Drivers" tab, assign fleet cars, and book sanctioned races they run while you spectate. Higher-tier drivers race faster, brake later, and pass more aggressively.',
          'On "Available Races", pick an offer and choose "Assign driver", or "Race myself" to take the wheel personally. Driving yourself awards 85% of the prize purse (15% goes to your pit crew) and incurs a 15-minute driver cooldown.',
          'Fleet cars and drivers both need recovery cooldowns between races — the "Reduced Cooldown" skill shortens them.',
          'Open "Scheduled Races" to spectate your driver on track or drop out before the green flag.',
          '"Manager" automation (Team Ops skill) can auto-assign idle drivers on a timer. "Shop App" notifies you on your phone when a race is ready to spectate.',
        ],
      },
      {
        id: 'sponsors-finances-and-skills',
        title: 'Sponsors, finances, and skills',
        body: [
          'Team money is separate from your personal wallet. Purses, entry fees, driver cuts, upkeep, and league fees all flow through the "Finances" ledger.',
          'Hired drivers take a 15% to 35% cut of race winnings based on experience tier. Driving yourself has a flat 15% crew share.',
          'Sponsor contracts unlock in League 2 on "Home", granting passive cash and XP bonuses up to a stacking cap.',
          'Facility operating costs tick on a regular schedule (bays, drivers, dyno, manager), so monitor your balance.',
          'Spend team XP across three trees: Team Ops (laptop, phone app, manager), QOL (dyno, garage slots, towing), and Driver (roster size, cooldown reduction, podium XP).',
        ],
      },
    ],
  },
  {
    id: 'tuning-shop',
    category: 'business',
    iconKey: 'building',
    relatedAppId: 'tuning-shop',
    title: 'Tuning Shop',
    description: 'Tuning business · customer jobs, parts, kits, and shop automation',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'The Tuning Shop is at Fast Auto on West Coast USA, next to the racetrack. Walk up to the facility marker to purchase the property and use the business computer.',
          'New customer jobs appear on the "Jobs" tab over time. You start with two active job slots — accept one, "Pull Out" the customer car in the garage, and work it on a lift.',
          'With a car on a lift, use the workshop "Parts" and "Tuning" views to build the job, then drive to the race named in the goal (drag strip, Short Track, Track, and similar).',
          'Beat the target time on the job card ("Goal" vs "Current"), return to the computer, and tap "Complete" to collect payout into the shop account.',
        ],
      },
      {
        id: 'hq-computer-and-phone',
        title: 'HQ, computer, and phone',
        body: [
          'The facility is the business: garage lifts, customer fleet storage, shop bank account, and the computer upstairs.',
          'Computer tabs are "Home", "Jobs", "Kits", "Inventory", "Techs", "Finances", and "Skill Trees". Accepting jobs, installing parts, saving kits, hiring techs, and spending upgrade XP all happen here.',
          'With a vehicle on a lift, the left sidebar shows "WORKSHOP" with "Parts" and "Tuning". Install work bills the shop account, not your personal wallet.',
          'The "Tuning Shop" phone app is optional — not the hub. Unlock it with the "Shop App" skill in Quality Of Life on "Skill Trees". Until then the app shows "Unlock skill to use this app".',
          'Phone tabs cover a subset: "Home" (active jobs, idle techs, balance), "Jobs" (accept, complete, or abandon remotely), "Techs", and "Finances". You cannot install parts or tune from the phone.',
        ],
      },
      {
        id: 'the-job-loop',
        title: 'The job loop',
        body: [
          'Jobs list a goal like "45 s Short Track" — a target lap or run time at a specific West Coast race. "Current" shows the best time logged for that job car at that event.',
          'Flow: accept from "New Jobs" → "Pull Out" on "Active Jobs" (one car per lift; extra lifts come from shop upgrades) → modify the build → drive to the event and run it → "Complete" when Current meets or beats Goal.',
          'New offers generate on a timer (about two minutes between rolls by default; "Marketing" speeds this up). Unaccepted jobs expire after about five minutes.',
          'Completion locks to the build that set the time. If you change parts after a good run, the card may say "Build changed — re-run the event to complete" until you run again with the current setup.',
          'Keep the customer car intact — heavy damage can lock the job ("Vehicle Damaged") until you "Abandon" it. "That\'ll Buff Out" raises the damage tolerance. Abandoning costs half the job payout from the shop account ("No Hard Feelings" and "I Give Up" reduce or remove that fee).',
          'Use "Filters" on the "Jobs" tab to manage blacklists, job notifications, and (with a Manager) which offers auto-assign to techs.',
        ],
      },
      {
        id: 'parts-tuning-and-kits',
        title: 'Parts, tuning, and kits',
        body: [
          '"Inventory" holds removed parts from customer builds — sell individual pieces or "Sell All Parts" to recover value into the shop account.',
          '"Dyno" (Shop Upgrades skill) adds live power and weight stats while you work on a car in the shop.',
          '"Kits" lets you save a proven parts-and-tune setup from a job you can complete, then "Apply to Vehicle" on a matching model later. "Kit Storage" skills add save slots; "Quick Installs" shortens apply time.',
          'Part and tune costs respect shop skills — "Part Suppliers" and "Cheap Tunes" cut install bills. Towing (Shop Upgrades) lets you haul a pulled-out car back to the garage after driving to events.',
          '"Personal Use" (late Quality Of Life) lets your own garage cars use the lifts, discounts, and tools while you are in the shop zone.',
        ],
      },
      {
        id: 'techs-and-automation',
        title: 'Techs and automation',
        body: [
          '"Shop Techs" (Automation skill tree) hires workers who accept jobs, spend build budget, and run events for you. Each tech bills operating cost on a schedule.',
          'Assign techs on the "Techs" tab or from the phone. A tech on a job builds automatically — build cost is a slice of the payout, with success, rebuild, and failure rules tied to Automation upgrades.',
          '"Manager" auto-assigns idle techs to new offers on a timer. "Manager Blacklist" keeps chosen models for manual work. "General Manager" assigns as soon as a tech is free.',
          'You can still hand-build jobs yourself: leave a job unassigned, pull the car out, and tap "Complete" when you beat the goal. Techs and manager are throughput tools, not required to play.',
        ],
      },
      {
        id: 'finances-and-skills',
        title: 'Finances and skills',
        body: [
          'Shop money is separate from your wallet. Job rewards, part purchases, penalties, and operating costs flow through the business account on "Finances".',
          'Operating costs tick for lifts, hired techs, and managers — watch the ledger. "Solar Panels" (late Shop Upgrades) removes those bills.',
          '"Bigger Books" adds active job slots beyond the starting two. Extra lifts ("Lift #2" through "Lift #4") let more cars or techs work at once.',
          'Spend shop XP on three trees on "Skill Trees": Quality Of Life (phone app, blacklists, kits, harder jobs, damage tolerance, personal use), Automation (techs, manager, reliability), and Shop Upgrades (towing, dyno, part discounts, marketing, solar).',
          'Harder job tiers unlock with "More Complicated" skills; "Brand Recognition" and "Race Recognition" bias which vehicles and race types appear in the offer pool.',
        ],
      },
    ],
  },
  {
    id: 'skills',
    category: 'business',
    iconKey: 'flag',
    relatedAppId: 'skills',
    title: 'Skills',
    description: 'Career progression · unlocks, branches, and perks',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Skills" app on your phone.',
          'Browse skill branches for driving, logistics, racing, business, public service, and other specialties.',
          'Tap a branch to see your level, perks already unlocked, and what comes next.',
          'Do the activities that grant XP in the branch you care about — jobs, races, deliveries, or business work as listed in each path.',
          'Return after sessions to review unlocks and pick your next focus.',
        ],
      },
      {
        id: 'what-skills-unlock',
        title: 'What skills unlock',
        body: [
          'Leveling skills can open better jobs, better rewards, new abilities, equipment access, or stronger career options.',
          'Some systems look at skill progress before offering advanced work, so your skill tree shapes what the career feeds you.',
        ],
      },
      {
        id: 'planning-your-path',
        title: 'Planning your path',
        body: [
          'Use "Skills" to decide what kind of career you are building instead of grinding random jobs.',
          'If a job type feels locked or low-paying, check whether the related skill branch needs another level first.',
        ],
      },
    ],
  },
  {
    id: 'phone-apps',
    category: 'phone',
    iconKey: 'tools',
    relatedAppId: 'app-store',
    title: 'Phone Apps',
    description: 'Install phone apps · jobs, finance, and utilities',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "App Store" from your phone home screen.',
          'Browse apps for jobs, money, property, vehicles, events, media, and tools.',
          'Tap an app to read what it does and whether you want it on your home screen.',
          'Tap "GET" on the list row, then "Install" on the detail screen to add it.',
          'Find newly installed apps on your home screen and open them when that part of the career matters.',
        ],
      },
      {
        id: 'what-to-install-first',
        title: 'What to install first',
        body: [
          'You do not need every app on day one. Install "Bank", "Marketplace", or a job app when you are ready to use that loop.',
          'Leaving apps uninstalled keeps your home screen cleaner until you actually need the feature.',
        ],
      },
      {
        id: 'managing-your-phone',
        title: 'Managing your phone',
        body: [
          'Use the "App Store" as the starting point when you want to unlock a new phone feature or learn what an app is for before adding it.',
          'If an installed app opens empty, the feature may not be available on your current map — that is normal, not a broken install.',
        ],
      },
    ],
  },
  {
    id: 'gallery',
    category: 'phone',
    iconKey: 'tools',
    relatedAppId: 'gallery',
    title: 'Gallery',
    description: 'Saved career photos · builds, trips, and milestones',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Take photos with the "Camera" app during moments you want to keep.',
          'Open "Gallery" from your phone home screen.',
          'Scroll through saved shots from vehicles, jobs, properties, and events.',
          'Tap a photo to view it larger when you want to compare builds or remember a win.',
        ],
      },
      {
        id: 'why-use-gallery',
        title: 'Why use Gallery',
        body: [
          'Gallery stores photos you take with the "Camera" app — builds, properties, events, and other career moments in one place on your phone.',
        ],
      },
    ],
  },
  {
    id: 'camera',
    category: 'phone',
    iconKey: 'tools',
    relatedAppId: 'camera',
    title: 'Camera',
    description: 'Take career photos · saves to Gallery',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Camera" app from your phone home screen.',
          'Frame the vehicle, location, or moment you want to keep.',
          'Take the photo using the on-screen capture control.',
          'Open "Gallery" later to review everything you have saved.',
        ],
      },
      {
        id: 'what-to-shoot',
        title: 'What to shoot',
        body: [
          'Photos save to "Gallery" automatically. Use "Camera" for vehicle builds, properties, events, or anything you want to review later on your phone.',
        ],
      },
    ],
  },
  {
    id: 'phone-settings',
    category: 'phone',
    iconKey: 'settings',
    relatedAppId: 'settings',
    title: 'Phone Settings',
    description: 'Phone layout and notifications',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open "Settings" from your phone home screen.',
          'Review layout, notification, and behavior options available in the app.',
          'Adjust home screen arrangement or app behavior to match how you play.',
          'Save or apply changes and return to the home screen to see the result.',
        ],
      },
      {
        id: 'layout-and-clutter',
        title: 'Layout and clutter',
        body: [
          'If the phone feels crowded, tune layout before uninstalling apps you still need elsewhere.',
          'Small layout changes can make repeated career use easier during long sessions.',
        ],
      },
      {
        id: 'notifications',
        title: 'Notifications',
        body: [
          'Notification settings live here instead of inside individual job or finance apps.',
          'Turn down channels you do not care about so important job and payment alerts stay visible.',
        ],
      },
    ],
  },
]

export function getGuideTopicById(id) {
  return GUIDE_TOPICS.find(topic => topic.id === id) || null
}

export function getGuideTopicByRelatedAppId(appId) {
  return GUIDE_TOPICS.find(topic => topic.relatedAppId === appId) || null
}

/** @deprecated use GUIDE_TOPICS */
export const GUIDE_WIKI_TOPICS = GUIDE_TOPICS
