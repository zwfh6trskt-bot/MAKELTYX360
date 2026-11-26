# Base de données MAKELTYX360 (Neon)

Projet Neon : `makeltyx360` (`cool-fire-90679138`), région Francfort, branche `main`, base `neondb`.

- **Neon Auth** : connexion admin (inscriptions désactivées).
- **Data API** : API REST utilisée par le site (CORS limité à `https://zwfh6trskt-bot.github.io`).
- `schema.sql` : tables, fonctions sécurisées, règles RLS. `products.sql` : produits.

Sécurité : un visiteur peut seulement lire les produits, passer une commande (`place_order`, prix recalculés côté serveur)
et lire le nombre de commandes du jour (`orders_today_count`). Les commandes ne sont lisibles que par un e-mail listé dans `public.admins`.

Ajouter un admin (Neon Console > SQL Editor) : créer le compte dans Auth > Users, puis
`insert into public.admins(email) values ('email@exemple.com');`

Horaires et seuil : `update public.settings set open_min = 480, close_min = 720, goal = 10;` (minutes depuis minuit, heure d'Alger).

Ouvrir exceptionnellement plus tard aujourd'hui (ex. jusqu'à minuit) :
`update public.settings set extra_date = (now() at time zone 'Africa/Algiers')::date, extra_close_min = 1440;`
Le lendemain, l'horaire normal revient tout seul.
