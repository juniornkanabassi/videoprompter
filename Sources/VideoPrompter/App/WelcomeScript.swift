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
    > Choose **Present**, then **Microphone** to check your sound. Close the popover and choose **Start reading**.

    Hello, and welcome. This is a practice script. Pause whenever you like. [Look at the camera.]

    ## Choose how to read

    Voice follow keeps your place as you speak. **Listening** means your words are being received. Choose Automatic scroll in **Settings**, under **Reading**, for a steady speed without a microphone.

    ## Make yourself comfortable

    Use **Text** on the presenter bar to make the words bigger or smaller. **Settings**, under **Reading**, holds fonts, spacing, colours and Mirror for teleprompter glass.

    Click a word to read from there. The arrow keys move between passages when the script has focus. **Back to start** returns to the beginning. **Edit script** lets you correct the words; choose **Save changes** when finished.

    ## Camera and recording

    **View** shows the script, the camera, or both. Choose a camera and use **Guides** to line up your shot. **Zebras** and **False colour** help check exposure. **Clean view** shows just the picture.

    **Record** sits beside **Start reading**. Each is a separate action. Choose **Stop recording** when finished, wait for **Saved**, then **Play** or **Show in Finder**. The library's **Recordings** button opens your takes.

    ## Your own scripts

    Choose **Paste Copied Text**, **New Script**, or **Import File…**. Imported Markdown stays linked to the original file. Changes in either place appear in the other.

    Headings, bold and italics work. You can delete this practice script and bring it back using **Welcome Script** in Help.
    """
}
