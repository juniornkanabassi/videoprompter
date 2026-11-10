import Foundation
import PrompterCore

/// The script a new library starts with. It doubles as the tour: a first-time user presents it and
/// reads it aloud, and each section asks them to try the feature it describes, so Voice, the
/// passage keys, stage directions and the camera are all met in the order they are needed.
/// Help > Getting Started Guide brings it back after it has been deleted.
enum WelcomeScript {
  static let title = "Welcome to Video Prompter"
  /// Set once a library has been offered the script, so deleting it is final until Help asks again.
  static let offeredKey = "welcomeScriptOffered"
  static let markdown = Features.recording ? recordingMarkdown : monitorMarkdown
  static let monitorMarkdown = """
    # Welcome to Video Prompter

    > [!note] Start here
    > Click **Open presenter**, then **Start reading**, and read this out loud. Voice follow is on, so the script moves when you speak.

    Hi, hello, this is Junior. [Look at the camera.]

    Thank you for using Video Prompter. Everything on this Mac is set up and ready to go.

    I stayed up until about midnight finishing this version, so I hope you enjoy it. This script shows you how everything works. Just read it out loud and it will follow you.

    ## Reading

    Voice follow listens to you and keeps your place. If you stop talking, it waits for you. [Pause for a second.]

    Press **Space** to pause. **Back to start** takes you to the first word.

    **Script language** is set to **Automatic**, so the app works out the language from your script. You can choose a language yourself in **Settings > Reading**.

    ## Other languages

    Video Prompter also reads in Spanish, French, German, Italian, Dutch and Portuguese. Paste a script in any of them, and the app switches language on its own.

    The first time you use a new language, stay connected to the internet so the Mac can download it.

    ## Set up the shot

    Choose **Set up the shot** to go back to the camera.

    The bar along the bottom has **Camera**, **Mic**, **Zebras**, **False colour**, **Guides**, **Adjust** and **Clean**.

    Choose **Camera** to pick your camera and how it is turned. Choose **Mic** to pick your microphone. If your microphone has two channels, you can use the left, the right or both.

    The mic meter on the right shows your level. Green is good. Yellow is loud. Red is too loud.

    ## Check exposure

    **Zebras** put stripes on the parts of the picture at the brightness you choose. **False colour** paints the picture by brightness, and your skin shows in pink when it is exposed right.

    Pick your skin tone in **Adjust > False colour**. The **Exposure key** in the top left explains the colours. Choose **Hide key** to tuck it away.

    ## Clean

    **Clean** shows only the picture. Press **Escape** to leave it.

    ## Your scripts

    Choose **Script** in the bar to open the editor while the presenter stays open. Paste or write your own script, and the library saves it for you.

    That is everything. Thank you again for using Video Prompter. [Smile.] Have fun.
    """
  private static let recordingMarkdown = """
    # Welcome to Video Prompter

    > [!note] Start here
    > Choose **Present**, then **Start reading**. Reading does not record. To check your sound first, open **Tools**, choose Microphone in **Tools section**, then **Check sound…**.

    Hello, and welcome. Pause whenever you like. [Look at the camera.]

    ## Choose how to read

    Voice follow keeps your place as you speak. Open **Tools**, choose Text, then **Reading mode…** to choose Voice follow or Automatic scroll. Automatic scroll waits for your Start delay, normally three seconds. The Cancel button stops the countdown. If reading needs attention, choose **Check reading…** beside the status for instructions and an automatic-scroll fallback.

    ## Make yourself comfortable

    Open **Tools** for **Smaller text** and **Larger text**. **More text settings…** opens Reading settings for fonts, spacing, colours and teleprompter mirroring. Changes apply to all scripts. Reading settings also include Reading presets.

    Click a word to read from there. The arrow keys move between passages when the script has focus. When paused, choose **Back to start** beside **Start reading** to try again without stopping a recording. Open **Tools**, then **Edit this script**. Choose **Save changes** when finished, or **Cancel editing** to keep the original.

    ## Camera and recording

    Choose **Show camera** before recording if only your script is showing. Under **Tools**, choose Camera in **Tools section**, then use **View** to choose Script only, Script and camera, or Camera view. **Choose camera…** selects your camera and **Framing guides…** helps you compose the picture.

    In the Exposure section of **Tools**, the zebra check marks bright areas and **Check brightness · False colour** helps compare brightness. **More exposure settings…** explains what to look for and how to adjust your camera. Under the camera, **Zebras**, **False colour**, **Guides**, **Mic level** and **Clean** switch each aid off and on without changing your saved choices, and the arrow beside one opens its settings. **Camera** opens the camera list.

    To retake a line, press Pause, click the word, then Start reading. The recording keeps going.

    **Clean presenter view** hides the script, framing guides and exposure aids in the presenter only. The Second monitor window keeps its overlays.

    **More camera settings…** opens Camera & Recording. Its Camera section offers **Open Second Monitor Window** for a separate window showing the same camera and recording. Shoot setups in Settings, or **Shoot setups…** under Tools, lets you save, apply, rename and delete complete setups. After Apply, **Restore Previous Setup** returns to your previous choices.

    **Record** and **Start reading** are separate actions. Choose **Stop recording** when finished, then **Play** to review it, or **Show in Finder** to find the file. A saved take with problems has a review action. The library's **Recordings** button opens your takes.

    ## Your own scripts

    Choose **Paste Copied Text**, **New Script**, or **Import File…**. Imported Markdown stays linked to the original file. Changes in either place appear in the other.

    Headings, bold and italics work. You can delete this guide and bring it back using **Getting Started Guide** in Help.
    """
}
