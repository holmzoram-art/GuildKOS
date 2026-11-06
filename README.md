# GuildKOS

En addon for WoW Forever. Du legger inn navn, og når en av dem er i nærheten får du:

- en lyd (Raid Warning som standard, spilles på Master-kanalen)
- rødt blink rundt skjermkanten
- stor tekst midt på skjermen og en linje i chat
- et lite «KOS i nærheten»-vindu som viser hvem som er rundt deg nå (du kan dra det dit du vil ha det)
- blinkende ikon på oppgavelinja hvis spillet ligger i bakgrunnen

## Guildlista

Guildlista er felles for alle i guilden som har addonen. Skriv navnet (og gjerne en grunn) i
`/kos`-vinduet og trykk «Legg til i guildlista». Alle med addonen har hele lista lagret hos seg, og
addonene holder hverandre oppdatert:

- Et nytt eller fjernet navn sendes med en gang til alle som er pålogget.
- Når noen logger på, sammenligner addonen lista med de andre og henter det som mangler. Den som
  var borte en uke, får altså alt som skjedde i mellomtiden, så lenge minst én annen med addonen er
  pålogget.
- Det er ingen grense på hvor mange navn lista kan ha.
- Fjerner noen et navn, blir det borte hos alle. Det kommer ikke tilbake fra noen med en gammel liste.
- Alle i guilden kan legge til og fjerne navn. Lista viser hvem som la til hvert navn.

## Min liste

Din egen liste er bare din. Den gjelder alle karakterene dine på kontoen, og blir aldri delt.

## Del lista som tekst

«Del lista» i vinduet (eller `/kos export`) viser hele lista som tekst, ett navn per linje. Kopier
den med Ctrl+C og lim den inn på Discord som backup. For å lese en liste inn igjen: lim den inn i
samme vindu og trykk «Til guildlista» eller «Til min liste».

```
Forræder - Gikk alliance
Sviker
```

## Guilden får beskjed

Når noen ser et navn fra guildlista, får de andre i guilden med addonen en linje i chat, for eksempel
«Forræder sett av Ola: The Crossroads, The Barrens». Lista i vinduet viser også hvor og når hvert
navn sist ble sett. Begge deler kan slås av.

## Drap blir kunngjort og telt

Når du eller noen i gruppa di dreper et navn fra guildlista, skriver addonen det i guildchat:

```
[KOS] Ola drepte Forræder i Ashenvale! Forræder er tatt 3 ganger. Ola har 5 KOS-drap.
```

- Alle i guilden ser meldingen, også de uten addonen.
- Addonen teller hvor mange ganger hvert navn er drept, og hvor mange KOS-drap hver i guilden har.
  `/kos top` viser topplista, og lista i vinduet viser «Drept 3 ganger, sist av Ola».
- Et drap fra petten din teller som ditt.
- Har en i gruppa di ikke addonen, kunngjør din addon drapet for dem.
- Drap på navn som bare står på din egen liste blir telt, men bare du får se dem.
- Kunngjøringen kan slås av i vinduet.

## Hvordan den finner folk

WoW Forever lar ikke addons lese combat-loggen. Derfor ser addonen etter folk i:

- **navneplater**, som gir det tidligste varselet. Fiendtlige navneplater må være slått på; skriv
  `/kos plates`.
- ditt target, musepeker og focus, og det gruppa di har i target
- `/say`, `/yell` og emotes. Ordene fra den andre faksjonen blir rotete, men navnet er ekte.

I battlegrounds og arenaer kan spillet skjule navn for addons. Der virker varslene og drapstellingen
dårligere eller ikke i det hele tatt. I åpen verden ser addonen navnene også i kamp.

## Kommandoer

| Kommando | Hva den gjør |
|---|---|
| `/kos` | åpner eller lukker vinduet |
| `/kos add Navn [grunn]` | legger navnet til i din liste |
| `/kos remove Navn` | fjerner navnet fra din liste |
| `/kos guild add Navn [grunn]` | legger navnet til på guildlista |
| `/kos guild remove Navn` | fjerner navnet fra guildlista |
| `/kos list` | skriver hele lista i chat, med antall drap |
| `/kos top` | viser hvem i guilden som har flest KOS-drap |
| `/kos export` eller `/kos import` | åpner vinduet for å dele lista som tekst |
| `/kos sync` | sammenligner lista med guilden med en gang |
| `/kos plates` | slår på fiendtlige navneplater |
| `/kos test` | viser et testvarsel |

## Installering

Kopier mappa `GuildKOS` til `World of Warcraft\_forever_\Interface\AddOns\`, og start spillet
eller skriv `/reload`.
