# Πρόταση για SuppressRepeats findings

Κατάσταση: πρόταση σχεδιασμού, δεν έχει υλοποιηθεί.

## Τι θέλουμε να πετύχουμε

Ένα finding που περιγράφει ένα συγκεκριμένο συμβάν πρέπει να εμφανίζεται όταν το παρατηρούμε πρώτη φορά. Αν οι επόμενοι έλεγχοι βρίσκουν ακριβώς το ίδιο συμβάν, θέλουμε να το κρατάμε στα αναλυτικά αποτελέσματα αλλά ως suppressed. Αν περάσουν τουλάχιστον 45 ημέρες χωρίς παρατήρηση του ίδιου finding, θέλουμε να εμφανιστεί ξανά όταν και εφόσον επιστρέψει.

Όσο το διάστημα μεταξύ διαδοχικών παρατηρήσεων παραμένει μικρότερο από 45 ημέρες, ο χρήστης δεν θα ειδοποιείται ξανά για το ίδιο finding. Οι 45 ημέρες επιτρέπουν ακόμα και μηνιαία εκτέλεση του `Get-ComputerHealth`.

Ο χρόνος μετράει από την τελευταία παρατήρηση, ακόμη κι αν το finding ήταν suppressed. Μετράει η ώρα του health check που το εντόπισε.

## Παράδειγμα με scheduled task

Το παρακάτω finding περιγράφει μια συγκεκριμένη αποτυχημένη εκτέλεση:

```text
Scheduled task '\enLogic\Execute WindowsUpdatesHelper' terminated with LastTaskResult=0x800710E0 (Either wrong password or win32 error 'The operator or administrator has refused the request'); Last run time 2026-10-18 20:03:03.
```

Τα στοιχεία που διακρίνουν το συμβάν είναι το full task path, το error code και το last run time. Το description περιλαμβάνει ήδη αυτά τα στοιχεία.

- Την πρώτη φορά που το βρίσκουμε, εμφανίζεται κανονικά.
- Αν το task δεν ξανατρέξει, οι επόμενοι έλεγχοι βρίσκουν το ίδιο finding και ανανεώνουν το SuppressRepeats state.
- Αν το task ξανατρέξει και αποτύχει, το νέο last run time αλλάζει το description και τη signature. Η νέα αποτυχημένη εκτέλεση εμφανίζεται αμέσως, εκτός αν υπάρχει άλλο ενεργό suppression που την καλύπτει.

Η ίδια αρχή μπορεί να χρησιμοποιηθεί για άλλα findings.

## Ο κανόνας των 45 ημερών

Για κάθε SuppressRepeats finding, ο runner διαβάζει το προηγούμενο state και αποφασίζει πώς θα εμφανιστεί στο τρέχον run. Μετά ενημερώνει την τελευταία παρατήρηση.

1. Ελέγχει πρώτα τα υφιστάμενα suppressions.
2. Αν δεν υπάρχει άλλο ενεργό suppression, ελέγχει αν έχει καταγραφεί το ίδιο SuppressRepeats finding μέσα στις προηγούμενες 45 ημέρες.
3. Αν υπάρχει πρόσφατη παρατήρηση, το finding είναι suppressed λόγω SuppressRepeats. Αν δεν υπάρχει, εμφανίζεται κανονικά με το αρχικό του severity.
4. Σε κάθε περίπτωση που το finding εντοπίστηκε, αποθηκεύει `LastSeenUtc = τώρα`, ακόμη κι αν το finding ήταν suppressed από SuppressRepeats ή από configured suppression.

Η απόφαση του τρέχοντος run πρέπει να προηγείται της ενημέρωσης. Διαφορετικά, θα κρύβαμε ακόμη και την πρώτη εμφάνιση. Η ίδια απόφαση πρέπει να ισχύει στην console και σε όλα τα reports που παράγονται από τα αποτελέσματα του run.

Η προτεινόμενη ακριβής συνθήκη είναι:

```text
SuppressRepeats suppression is active when:
    NowUtc < PreviousLastSeenUtc + 45 days
```

Στις ακριβώς 45 ημέρες το SuppressRepeats suppression έχει λήξει. Χρησιμοποιούμε UTC timestamps, ώστε αλλαγές timezone ή θερινής ώρας να μην αλλάζουν το χρονικό διάστημα.

| Παρατηρήσεις | Συμπεριφορά |
| --- | --- |
| Πρώτη παρατήρηση, χωρίς άλλο suppression | Εμφανίζεται κανονικά και αποθηκεύεται η παρατήρηση. |
| Το ίδιο finding κάθε ημέρα επί πολλούς μήνες | Εμφανίζεται μόνο την πρώτη φορά. Η λήξη ανανεώνεται σε κάθε παρατήρηση. |
| Το ίδιο finding κάθε μήνα | Παραμένει suppressed εφόσον κάθε διάστημα είναι μικρότερο από 45 ημέρες. |
| Επιστροφή 44 ημέρες μετά την τελευταία παρατήρηση | Παραμένει suppressed και ανανεώνεται η τελευταία παρατήρηση. |
| Επιστροφή 45 ή περισσότερες ημέρες μετά την τελευταία παρατήρηση | Εμφανίζεται ξανά και ξεκινά νέο διάστημα. |
| Το finding δεν εμφανίζεται σε ένα run | Το state του δεν ανανεώνεται και δεν διαγράφεται αμέσως. |

Ένα finding που παρατηρείται συνεχώς μπορεί να μείνει suppressed επ' αόριστον. Αυτό είναι η επιθυμητή συμπεριφορά για το ίδιο παλιό συμβάν.

## Δήλωση ανά finding

Το `HealthTest-ScheduledTasks` παράγει διαφορετικούς τύπους findings. Η αρχική εφαρμογή του SuppressRepeats θα αφορά μόνο αποτυχημένες εκτελέσεις που αναγνωρίζονται από συγκεκριμένο last run time.

| Τύπος finding | Προτεινόμενη συμπεριφορά |
| --- | --- |
| Αποτυχημένη εκτέλεση με συγκεκριμένο last run time | συμπεριφορά SuppressRepeats |
| Αποτυχημένη εκτέλεση με άγνωστο last run time | Κανονική, επειδή δεν μπορούμε να διακρίνουμε αξιόπιστα τις εκτελέσεις. |
| Disabled task | Κανονική |
| Missed runs | Κανονική |
| Stale task | Κανονική |
| Αποτυχία συλλογής ή ανάγνωσης δεδομένων | Κανονική |

Το health test δηλώνει ρητά ποια findings ακολουθούν SuppressRepeats, στο σημείο όπου τα παράγει. Προτείνεται ένα προαιρετικό prefix μετά το υπάρχον severity:

```powershell
Write-Warning "[$level][SuppressRepeats] Scheduled task '$taskPath' terminated with LastTaskResult=$resultHex; Last run time $lastRunText.`n$details"
```

Το παράδειγμα δείχνει την προτεινόμενη σύνταξη. Δεν είναι σήμερα υποστηριζόμενο API. Το τελικό description μπορεί να περιλαμβάνει και την περιγραφή του error, όπως στο πλήρες παράδειγμα παραπάνω.

Ο runner αναγνωρίζει το `[SuppressRepeats]`, το μετατρέπει σε property `SuppressRepeats = $true` και το αφαιρεί πριν δημιουργήσει το καθαρό description και υπολογίσει τη signature. Έτσι η προσθήκη του marker δεν αλλάζει την ταυτότητα του finding. Το severity διατηρείται.

Η συμπεριφορά αφορά findings επιπέδου `NOTICE`, `WARNING` και `FAILURE`. Τα `PASS`, `INFO`, `DEBUG` και τα errors του ίδιου του runner δεν αποκτούν αυτόματο SuppressRepeats suppression.

Το `HealthTest-ScheduledTasks` παραμένει ένα test. Τα findings χωρίς marker συνεχίζουν να ακολουθούν την κανονική συμπεριφορά. Ο runner αναλαμβάνει κεντρικά το state και το suppression, ώστε τα επιμέρους health tests να χρειάζεται μόνο να δηλώνουν την πρόθεσή τους.

## Ταυτότητα και state

Το SuppressRepeats χρησιμοποιεί την υπάρχουσα signature του description. Τα details παραμένουν εκτός signature, ώστε μια αλλαγή μόνο στα details να μην δημιουργεί νέα ειδοποίηση.

Το προτεινόμενο αρχείο είναι `state\suppress_repeats.json`, κάτω από το installation root και τοπικά στον υπολογιστή που ελέγχεται. Η ταυτότητα κάθε εγγραφής είναι το ζεύγος test name και finding signature. Έτσι διαχωρίζονται διαφορετικά tests, ενώ η τοπική αποθήκευση διαχωρίζει τους υπολογιστές.

Το ελάχιστο state για τον χρονικό κανόνα περιέχει:

```json
[
  {
    "TestName": "HealthTest-ScheduledTasks",
    "Hash": "1234abcd",
    "FirstSeenUtc": "2026-10-08T09:00:01Z",
    "LastSeenUtc": "2026-10-22T09:00:00Z"
  }
]
```


Η signature στο παράδειγμα είναι ενδεικτική. Η λήξη υπολογίζεται ως `LastSeenUtc + 45 ημέρες`. Δεν αποθηκεύουμε και δεύτερη ημερομηνία λήξης για το ίδιο γεγονός.

Το state πρέπει να επιβιώνει μεταξύ runs και code updates. Αν δεν υπάρχει προηγούμενο SuppressRepeats state, η πρώτη παρατήρηση εμφανίζεται κανονικά, με την επιφύλαξη των ήδη ενεργών suppressions.

## Διαχωρισμός από τα manual suppressions

Οι manual επιλογές παραμένουν στον υπάρχοντα μηχανισμό. Το SuppressRepeats δεν γράφει αυτόματες εγγραφές στο `Get-ComputerHealth.sigs-to-suppress.txt` και δεν αλλάζει τις ημερομηνίες ή τη μονιμότητα των υφιστάμενων επιλογών.

Στα structured findings προτείνονται τα εξής:

| Property | Σημασία |
| --- | --- |
| `SuppressRepeats` | Το finding έχει δηλωθεί ότι ακολουθεί τη συμπεριφορά SuppressRepeats. |
| `Suppressed` | Το finding είναι suppressed στο συγκεκριμένο run, από οποιαδήποτε ισχύουσα αιτία. |
| `SuppressionSource` | Η αιτία που καθόρισε το suppression του συγκεκριμένου run. |

Για το νέο αυτόματο suppression το `SuppressionSource` είναι `SuppressRepeats`. Για τις εγγραφές από το υπάρχον config προτείνεται η τιμή `Configured`, επειδή εκεί σήμερα συνυπάρχουν manual suppressions και policy baselines. Η πηγή είναι κενή όταν το finding δεν είναι suppressed. Το υπάρχον tag `Suppressed` χρειάζεται δική του διακριτή τιμή, αν η καταγραφή πηγής επεκταθεί και σε αυτό.

Η πρώτη εμφάνιση ενός SuppressRepeats finding έχει `SuppressRepeats = $true` και `Suppressed = $false`. Το ότι αποθηκεύτηκε state για τα επόμενα runs δεν αλλάζει αυτή την απόφαση.

| Ισχύουσα κατάσταση | Αποτέλεσμα |
| --- | --- |
| Υπάρχει ενεργό configured suppression | Suppressed με πηγή `Configured`. |
| Δεν υπάρχει άλλο ενεργό suppression και υπάρχει πρόσφατη SuppressRepeats παρατήρηση | Suppressed με πηγή `SuppressRepeats`. |
| Δεν ισχύει καμία αιτία suppression | Κανονική εμφάνιση. |

Αν ένα finding καλύπτεται και από τους δύο μηχανισμούς, η πηγή του report είναι `Configured`. Η παρατήρηση SuppressRepeats ανανεώνεται κανονικά, χωρίς να τροποποιείται το configured suppression.

Με αυτή την προτεραιότητα, η λήξη ενός manual suppression δεν εγγυάται νέα ειδοποίηση. Αν το finding παρατηρείται συνεχώς, το SuppressRepeats μπορεί να εξακολουθεί να το κρύβει.

## Συμπεριφορά στα reports

Η πρώτη εμφάνιση και η επιστροφή μετά τη λήξη εμφανίζονται κανονικά, με το αρχικό severity. Οι επαναλήψεις παραμένουν στα structured αποτελέσματα και στα αναλυτικά reports ως suppressed. Οι υφιστάμενοι κανόνες προβολής suppressed findings εξακολουθούν να εφαρμόζονται.

Τα reports πρέπει να διατηρούν την πληροφορία `SuppressRepeats` και `SuppressionSource`, ώστε να μπορούν να δείχνουν "Suppressed by SuppressRepeats". Στα αναλυτικά στοιχεία μπορεί να εμφανίζεται και η τελευταία παρατήρηση από το SuppressRepeats state.

Το αυτόματο SuppressRepeats suppression δεν μετατρέπεται σε `Postponed`. Σήμερα τα reports χρησιμοποιούν το `SuppressedUntil` για να εμφανίζουν προσωρινά suppressions ως postponed κοντά στη λήξη τους. Η νέα λογική πρέπει να διακρίνει την πηγή και να μην αντιμετωπίζει το SuppressRepeats ως χειροκίνητη αναβολή αντιμετώπισης. Το `SuppressedUntil` του υπάρχοντος μηχανισμού δεν αντικαθίσταται από το υπολογιζόμενο SuppressRepeats όριο.

Οι ιδιότητες αυτές πρέπει να μεταφέρονται μέχρι τα τελικά reports, και όταν το run γίνεται μέσω `Invoke-GetComputerHealth.ps1` σε τοπικό ή απομακρυσμένο υπολογιστή.

## Όρια και εκκρεμότητες

Η απουσία παρατήρησης δεν αποδεικνύει ότι λύθηκε το πρόβλημα. Αν ο υπολογιστής είναι offline ή το test δεν τρέξει για τουλάχιστον 45 ημέρες, το ίδιο finding θα εμφανιστεί ξανά όταν το παρατηρήσουμε. Αυτό είναι αποδεκτό για τον προτεινόμενο μηχανισμό.

Η καταγραφή μιας πρώτης εμφάνισης σημαίνει ότι το finding συμπεριλήφθηκε κανονικά στα αποτελέσματα. Δεν αποτελεί επιβεβαίωση ότι ο χρήστης παρέλαβε ή διάβασε το report.

Χρειάζεται επίσης κανόνας για αύξηση severity. Σήμερα η signature δεν περιλαμβάνει το level. Ένα ίδιο description που αλλάζει από `WARNING` σε `FAILURE` μπορεί επομένως να εξακολουθεί να θεωρείται το ίδιο finding.

Η αύξηση severity δεν προκαλεί νέα εμφάνιση.

Σε αποτυχία ανάγνωσης ή αποθήκευσης του SuppressRepeats state, η υλοποίηση πρέπει να αποφεύγει τη σιωπηρή απώλεια findings. Μπορεί να προκύψουν επαναλαμβανόμενες ειδοποιήσεις και πρέπει να αναφέρεται το πρόβλημα του state χωρίς να γίνεται το ίδιο SuppressRepeats-suppressed.

## Έλεγχοι για την υλοποίηση

Η υλοποίηση πρέπει να ελεγχθεί τουλάχιστον για τις παρακάτω συμπεριφορές:

- Η πρώτη παρατήρηση παραμένει ορατή σε console και reports, παρότι αποθηκεύεται state.
- Οι επαναλήψεις ανανεώνουν την τελευταία παρατήρηση ακόμη κι όταν είναι suppressed.
- Η μηνιαία παρατήρηση του ίδιου finding δεν παράγει επαναλαμβανόμενες ειδοποιήσεις.
- Η επιστροφή πριν από τις 45 ημέρες παραμένει suppressed. Στο όριο των 45 ημερών και μετά εμφανίζεται ξανά.
- Ένα run χωρίς το finding δεν ανανεώνει το state του.
- Νέο last run time ή νέο error δημιουργεί νέα εμφάνιση. Αλλαγές μόνο στα details δεν την προκαλούν.
- Το `[SuppressRepeats]` αφαιρείται πριν από τη signature και το description των reports. Το severity διατηρείται.
- Τα υπόλοιπα findings του `HealthTest-ScheduledTasks`, μαζί με failures συλλογής δεδομένων, διατηρούν την κανονική συμπεριφορά.
- Το SuppressRepeats δεν συντομεύει, ανανεώνει ή αντικαθιστά configured suppressions. Η πηγή και η προτεραιότητα αποτυπώνονται σωστά.
- SuppressRepeats suppressions δεν εμφανίζονται ως `Postponed` και τα σχετικά properties επιβιώνουν μέχρι τα τελικά reports.
- Το state παραμένει ανεξάρτητο ανά υπολογιστή και test και διατηρείται μεταξύ runs.
- Η απουσία ή αποτυχία πρόσβασης στο state δεν αποκρύπτει σιωπηρά νέα findings.

Μετά την απόφαση για την αύξηση severity θα προστεθούν αντίστοιχα tests. Αν επιλεγεί υποχρεωτική υπενθύμιση στη λήξη manual suppression, θα χρειαστούν και tests για την αλληλεπίδρασή της με το SuppressRepeats.

## Σχετικά αρχεία

- [Συμβάσεις των built-in health tests](../contributor/built-in-health-tests.md).
- [Σχεδιασμός findings και περιορισμός θορύβου](health-findings-and-noise.md).
- [Ροή του Invoke-GetComputerHealth](invoke-getcomputerhealth-flow.md).
- [Get-ComputerHealth.ps1](../../Get-ComputerHealth.ps1), parsing των findings και εκτέλεση των tests.
- [lib-write-log-objects.ps1](../../lib-write-log-objects.ps1), signatures και log records.
- [HealthTest-ScheduledTasks.ps1](../../health-tests/HealthTest-ScheduledTasks.ps1), αρχική εφαρμογή ανά finding.
- [reporting.ps1](../../reporting.ps1), προβολή suppressions και postponed findings.
