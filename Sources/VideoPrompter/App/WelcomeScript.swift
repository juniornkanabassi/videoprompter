import Foundation

/// The script a new library starts with. It doubles as the tour: a first-time user presents it and
/// reads it aloud, and each section asks them to try the feature it describes, so Voice, the
/// passage keys, stage directions and the camera are all met in the order they are needed.
/// Help > Getting Started Guide brings it back after it has been deleted.
enum WelcomeScript {
  static let title = "Welcome to Video Prompter"
  /// Set once a library has been offered the script, so deleting it is final until Help asks again.
  static let offeredKey = "welcomeScriptOffered"
  static let markdown = """
    # Welcome to Video Prompter

    > [!note] Start here
    > Choose **Present**, then **Microphone** to check your sound. Close the popover and choose **Start reading**. Reading does not record. Choose **Record** separately to save a video.

    Hello, and welcome. This is a practice script. Pause whenever you like. [Look at the camera.]

    ## Choose how to read

    Voice follow keeps your place as you speak. **Listening** means your words are being received. Choose **Reading mode** to switch mode or adjust the automatic speed. Automatic scroll waits for the **Start delay**, normally three seconds. **Cancel countdown** stops the countdown.

    ## Make yourself comfortable

    Use **Text** to make the words bigger or smaller. **More → Settings…**, under **Reading**, holds fonts, spacing, colours and Mirror for teleprompter glass.

    Click a word to read from there. The arrow keys move between passages when the script has focus. Open **More → Back to start**, or **More → Edit script**; choose **Save changes** when finished. **Back to start** returns to the opening without stopping a recording.

    ## Camera and recording

    **More → View** shows the script, the camera, or both in this presenter. Open **Camera** to choose your camera and **Framing guides**. **Zebras** and **False colour** under **Exposure** help check exposure and stay available during a take. **Clean view** removes the script and picture overlays while keeping reading and recording controls available.

    **Open Camera Monitor** in the Window menu opens a second-display view. Both windows share the camera and recording setup.

    **Record** sits beside **Start reading**. Each is a separate action. Choose **Stop recording** when finished, wait for **Show saved take…**, then **Play**, or use **Show in Finder** directly. **Saved with problems** names a fault: review it before recording again. The library's **Recordings** button opens your takes.

    ## Your own scripts

    Choose **Paste Copied Text**, **New Script**, or **Import File…**. Imported Markdown stays linked to the original file. Changes in either place appear in the other.

    Headings, bold and italics work. You can delete this practice script and bring it back using **Getting Started Guide** in Help.
    """
}
