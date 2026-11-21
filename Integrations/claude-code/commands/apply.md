---
description: Write what was changed in tango back into the code it was sketched from.
argument-hint: [anything to leave out or to watch for]
---

The person has played with a sketch in tango and wants their changes in the code. $ARGUMENTS

1. Call the tango tool `get_changes` with `pictures` true. If it says there is no starting point, the document was not sketched with `/tango:sketch`: say so and stop. If nothing changed, say so and stop.
2. If you have not read it in this conversation, call `get_reference` and read "Carrying changes back".
3. For each change, open the code its `source` names and make the change there, in the code's own way:
   - A value that comes from a token or a shared style: change the token (and say how many places that touches) or override it locally, whichever the change calls for. Ask when it is not clear.
   - `motion` entries give each animation's numbers as SwiftUI and Reanimated write them. Use them as given.
   - An added view is new code beside what its `parent` and `after` name; a removed view is removed; new patches and cables describe behavior to write.
4. Build or typecheck the code if the project makes that quick.
5. Tell the person what you changed, file by file, and list anything you could not carry over and why.
6. Call `mark_baseline`, so the next `/tango:apply` starts from here.

Do not commit. The person reviews the diff.
