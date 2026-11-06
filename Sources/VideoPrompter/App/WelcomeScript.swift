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
    > This is a practice script. Lines like this one are notes for you: they show in the editor but never in the presenter, and Voice ignores them. Press **Present** in the toolbar, then **Start reading**, and read the rest out loud.

    Hello, and welcome. This is a short script to practise with. You can pause whenever you like. [Look at the camera, not the screen.]

    ## Choose how to read

    Open **Set up this take** in the presenter. Voice follow keeps your place as you speak. Automatic scroll moves at a steady speed without a microphone, and you can set its speed here.

    For Voice follow, open **Microphones** in **Set up this take** to check your microphone and spoken language. Press **Test microphone** and speak normally. When you start reading, wait for Preparing to finish, then read the script aloud. Listening means speech recognition has received your words.

    ## Make yourself comfortable

    Use **Set up this take** to change the reading text size. The library’s **Reading settings** also has fonts, spacing, colours and Mirror for teleprompter glass.

    Click a word to read from there. The arrow keys move between passages. **Back to start** returns to the beginning. **Pause** stops the script. **Edit script** lets you make a correction; choose **Finish editing** to save it.

    ## Camera and recording

    The **View** menu lets you show your script, your camera, or both. Choose your camera and use **Framing guides** to line up your shot. You can also select a passage and choose **Pin Selected Text over Camera** to pin those words over the picture.

    **Start reading** moves the script. **Record camera** records the camera and the microphone named beside it. These are separate actions. Press **Stop recording** when finished, wait for Saved, then choose **Show in Finder** to find your take. Recordings go in Movies, inside Video Prompter.

    ## Your own scripts

    Write a new script with **New Script**, paste one with **Paste as New Script**, or import a Word document, PDF, text file or Markdown file. A Markdown file you import stays linked, so edits here change the original, and edits to the original show up here.

    Headings, bold and italics all work, and a heading is a handy way to split a long script into sections.

    That is the whole tour. You can delete this script whenever you like, and bring it back at any time from **Welcome Script** in the Help menu. [Smile. You made it to the end.]
    """
}
