import Foundation

/// The script a new library starts with. It doubles as the tour: a first-time user presents it and
/// reads it aloud, and each section asks them to try the feature it describes, so Voice, the
/// passage keys, stage directions and the camera are all met in the order they are needed.
/// Help > Welcome Script brings it back after it has been deleted.
enum WelcomeScript {
  static let title = "Welcome to Video Prompter"
  /// Set once a library has been offered the script, so deleting it is final until Help asks again.
  static let offeredKey = "welcomeScriptOffered"
  static let markdown = """
    # Welcome to Video Prompter

    > [!note] Start here
    > This is a practice script. Lines like this one are notes for you: they show in the editor but never in the presenter, and Voice ignores them. Press **Present** in the toolbar, then **Start**, and read the rest out loud.

    Hello, and welcome to Video Prompter. If you are reading this in the presenter, you have already done the hardest part. [Look at the camera, not the screen.]

    Words in square brackets are stage directions, such as a reminder to look at the camera. They are hidden in the presenter until you turn on Show stage directions under More in Settings, and Voice skips past them either way, so you never have to say them.

    ## Voice or Manual

    There are two ways for the script to move. In Voice, the app listens through your microphone and follows the words as you say them, all on your Mac. Pause for a moment and it waits for you. Skip a line or say something slightly different and it catches up when your words match the script again.

    In Manual, the script scrolls at a steady speed that you set in words per minute, and no microphone is needed. You choose between them in Settings, on the right of the library window.

    ## Moving around

    Each paragraph is a passage. Press the right arrow key to jump to the next one and the left arrow key to go back. Try it now, then come back here.

    Click any word to carry on reading from there. **Back to start** takes you to the first word, and **Pause** stops everything until you press **Start** again. If you spot a mistake while you are recording, choose **Edit script**, fix it, and press Command and Return to save.

    ## Making it comfortable

    The line across the presenter is the reading line: keep your eyes near it and the script comes to you. In Settings you can change the text size, the font and the colours, and **More** shows extra options such as line spacing and the width of the text column.

    If you read through teleprompter glass, turn on mirroring in Settings so the words read the right way round. For a large screen, choose **Presenter Full Screen** from the Prompter menu.

    ## Camera and recording

    Video Prompter can show your camera behind the script, so you can check your framing while you read. Turn the camera on from the presenter's controls and allow camera access when macOS asks. Framing guides help you line up your shot.

    To record, open the Camera window from the Window menu and press **Record**. Recordings are saved in the Video Prompter folder inside Movies.

    ## Your own scripts

    Write a new script with **New Script**, paste one with **Paste as New Script**, or import a Word document, PDF, text file or Markdown file. A Markdown file you import stays linked, so edits here change the original, and edits to the original show up here.

    Headings, bold and italics all work, and a heading is a handy way to split a long script into sections.

    That is the whole tour. You can delete this script whenever you like, and bring it back at any time from **Welcome Script** in the Help menu. [Smile. You made it to the end.]
    """
}
