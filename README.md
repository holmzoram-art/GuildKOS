# GuildKOS

En addon for WoW Forever. Du legger inn navn, og når en av dem er i nærheten får du:

- en lyd (Raid Warning som standard, spilles på Master-kanalen)
- rødt blink rundt skjermkanten
- stor tekst øverst på skjermen og en linje i chat
- et lite «KOS i nærheten»-vindu som viser hvem som er sett det siste minuttet. Trykk «Test» i
  `/kos`-vinduet for å få det fram, og dra det dit du vil ha det.
- blinkende ikon på oppgavelinja hvis spillet ligger i bakgrunnen

Første gang addonen lastes, står «Nektarion Stormhoof» på lista di med grunnen «Test», så du kan
prøve varslene med en gang. Fjern navnet med X-en når du er ferdig; det kommer ikke tilbake.

Hold musa over et navn i lista for å se alt om det: grunn, drap, hvor og når det sist ble sett, og
hvem som la det til.

## Navn

I WoW Forever har alle karakterer fornavn og etternavn. Skriv begge, for eksempel
«Nektarion Stormhoof». Fornavn alene er ikke unikt: skriver du bare «Nektarion», varsler addonen på
alle som heter Nektarion, uansett etternavn. Store og små bokstaver spiller ingen rolle.

## Guildlista

Guildlista er felles for alle i guilden som har addonen. Skriv navnet (og gjerne en grunn) i
`/kos`-vinduet og trykk «Legg til på guildlista». Alle med addonen har hele lista lagret hos seg, og
addonene holder hverandre oppdatert:

- Et nytt eller fjernet navn sendes med en gang til alle som er pålogget.
- Når noen logger på, sammenligner addonen lista med de andre og henter det som mangler. Den som
  var borte en uke, får altså alt som skjedde i mellomtiden, så lenge minst én annen med addonen er
  pålogget.
- Det er ingen grense for hvor mange navn lista kan ha.
- Fjerner noen et navn, blir det borte hos alle. Det kommer ikke tilbake fra noen med en gammel liste.
- Alle i guilden kan legge til og fjerne navn. Lista viser hvem som la til hvert navn.
- X-en ved et guildnavn fjerner det for hele guilden. Addonen spør først.

## Min liste

Din egen liste gjelder alle karakterene dine på kontoen, og addonen sender den aldri til andre. Den er
likevel med når du bruker «Del lista».

## Del lista som tekst

«Del lista» i vinduet (eller `/kos export`) viser hele lista som tekst, ett navn per linje. Kopier
den med Ctrl+C og lim den inn på Discord som backup. For å lese en liste inn igjen: lim den inn i
samme vindu og trykk «Til guildlista» eller «Til min liste».

```
Nektarion Stormhoof - Gikk alliance
Sviker Svikersen
```

## Guilden får beskjed

Når noen ser et navn fra guildlista, får de andre i guilden med addonen en linje i chat, for eksempel
«Forræder sett av Ola: The Crossroads, The Barrens». Lista i vinduet viser også hvor og når hvert
navn sist ble sett. Begge deler kan slås av.

Ingen spam: guilden hører om samme navn høyst én gang per 10 minutter, uansett hvor mange som ser
ham. Har du selv fått varsel på ham, får du heller ikke guildens melding om ham i den tiden.

## Drap blir kunngjort og telt

Når du eller noen i gruppa di dreper et navn fra guildlista, skriver addonen det i guildchat:

```
[KOS] Ola drepte Forræder i Ashenvale! Forræder er tatt 3 ganger. Ola har 5 KOS-drap.
```

- Alle i guilden ser meldingen, også de uten addonen.
- Addonen teller hvor mange ganger hvert navn er drept, og hvor mange KOS-drap hver i guilden har.
  `/kos top` viser topplista, og lista i vinduet viser «Drept 3 ganger, sist av Ola».
- Et drap fra petten din teller som ditt.
- Har en i gruppa di ikke addonen, kunngjør din addon drapet for dem. Det kommer bare én melding.
- Ingen spam: blir samme navn drept igjen innen 10 minutter, telles drapet, men guildchat får bare
  den første meldingen.
- Drap på navn som bare står på din egen liste blir telt, men bare du får se dem.
- Kunngjøringen kan slås av i vinduet.

## Hvordan den finner folk

WoW Forever lar ikke addons lese combat-loggen. Derfor ser addonen etter folk i:

- **navneplater**, som gir det tidligste varselet. Fiendtlige navneplater må være slått på; skriv
  `/kos plates`. Med «Navneplater på lang avstand» i vinduet vises de så langt unna som spillet
  tillater (opptil 60 meter). Avstanden du hadde før, kommer tilbake når du slår det av.
- ditt target, musepeker og focus, og det gruppa di har i target
- hvem target-en din, focus-en din eller noen med navneplate har i target. Da fanges også folk du
  ikke ser selv.
- `/say`, `/yell` og emotes. Ordene fra den andre faksjonen blir rotete, men navnet er ekte.
- **Battle.net-vennelista**: står karakteren til en av vennene dine på lista, får du varsel når den
  er i samme sone som deg, én gang per sone. Vennelista viser sonen, ikke hvor langt unna. Ingenting
  om vennene dine deles med guilden.

I battlegrounds og arenaer kan spillet skjule navn for addons. Der virker varslene og drapstellingen
dårligere eller ikke i det hele tatt. I åpen verden ser addonen navnene også i kamp.

## Kommandoer

| Kommando | Hva den gjør |
|---|---|
| `/kos` | åpner eller lukker vinduet |
| `/kos add Fornavn Etternavn - grunn` | legger navnet til på din liste |
| `/kos remove Fornavn Etternavn` | fjerner navnet fra din liste |
| `/kos guild add Fornavn Etternavn - grunn` | legger navnet til på guildlista |
| `/kos guild remove Fornavn Etternavn` | fjerner navnet fra guildlista |
| `/kos list` | skriver hele lista i chat, med antall drap |
| `/kos top` | viser hvem i guilden som har flest KOS-drap |
| `/kos export` eller `/kos import` | åpner vinduet for å dele lista som tekst |
| `/kos sync` | sammenligner lista med guilden med en gang |
| `/kos status` | viser guild, antall navn, siste synk og hvem addonen har hørt fra |
| `/kos plates` | slår på fiendtlige navneplater |
| `/kos test` | viser et testvarsel |

## Installering

Kopier mappa `GuildKOS` til `World of Warcraft\_forever_\Interface\AddOns\`, og start spillet
eller skriv `/reload`.
