# VoxoL dictation acceptance script

Use a quiet room, select the matching **Spoken language** in Dictation Studio, focus an
editable field, hold `⌥ Space`, read one line naturally, then release. Do not add words that
are not written below.

## French

1. **Clean phrase**

   > Bonjour, je vais envoyer le rapport demain matin.

2. **Explicit correction**

   > Envoie le rapport mardi, non, mercredi matin.

3. **Fillers and repetition**

   > Euh, je, je voulais confirmer que la réunion commence à neuf heures.

4. **Structured list**

   > Premièrement, vérifier le budget. Deuxièmement, appeler Camille. Troisièmement, envoyer le contrat.

5. **Protected facts**

   > Le budget est de quatre mille cinq cents euros et la livraison est prévue le vingt-quatre juillet deux mille vingt-six.

6. **Technical terms**

   > Dans Cursor, lance npm test, puis ouvre le fichier slash source slash auth point swift.

## English

1. **Clean phrase**

   > Hello, I will send the report tomorrow morning.

2. **Explicit correction**

   > Send the report Tuesday, actually Wednesday morning.

3. **Structured list**

   > First, review the budget. Second, call Maya. Third, send the contract.

## What to check

- The capsule stays in listening mode for as long as the shortcut is held.
- French and English never switch language when their explicit mode is selected.
- The result appears in the focused field without a manual `⌘V`.
- Dictation Studio shows the recognition engine, recognition time, cleanup time and total
  release-to-insertion time for the last dictation.
- Short clean phrases should be inserted in under one second after model warm-up. Complex
  faithful cleanup may still exceed one second while the lightweight cleanup model is being
  evaluated.
