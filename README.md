# BioPulse PPG: Real-time Heart Rate Analysis via Photoplethysmography

<p align="center">
  <img src="screenshots/icon.png" width="100px" alt="App Icon"/><br/>
  <b>BioPulse PPG - Graduation Thesis Project</b>
</p>

## 📋 Project Overview
**BioPulse PPG** is an innovative mobile application that leverages **Photoplethysmography (PPG)** technology to monitor heart rate and blood pressure indicators in real-time. This project, developed as a graduation thesis for Electronics & IoT, focuses on acquiring and processing raw PPG signals captured by a smartphone camera.

## 🚀 Key Technical Features (AI & Signal Processing Focus)

* **PPG Signal Acquisition:** Implementation of high-frequency frame capture and color channel analysis to acquire high-quality raw PPG signals.
* **Real-time Signal Processing:** Developed advanced algorithms for noise reduction, motion artifact removal, and signal smoothing.
* **PPG Morphology Analysis:** Extracted key morphological features, such as systolic peaks and diastolic troughs, to achieve precise heart rate estimation.
* **AI-Assisted Analysis:** Integrated AI capabilities to provide personalized health insights based on the collected physiological data.

## 🛠 Tech Stack

* **Framework:** Flutter (Dart)
* **Core Logic:** Fast signal processing and peak detection algorithms implemented in Dart.

---

## 📱 Application Demo

Explore the core functionalities of the **BioPulse PPG** application through these screenshots:

<table style="width:100%; text-align:center;">
  <tr>
    <td style="width:50%;">
      <img src="screenshots/ui_start.png" width="300px" alt="Main Measurement Interface"/><br/>
      <b>1. Ready to Measure</b><br/>
      The intuitive dashboard where users start the measurement process, with a placeholder for the real-time PPG waveform.
    </td>
    <td style="width:50%;">
      <img src="screenshots/ui_result.png" width="300px" alt="Heart Rate and PPG Waveform"/><br/>
      <b>2. Real-time Results</b><br/>
      Displays the calculated Heart Rate (BPM) and, most importantly, the **live raw PPG signal** extracted from the camera feed.
    </td>
  </tr>
  <tr>
    <td>
      <img src="screenshots/ui_history.png" width="300px" alt="Data History Log"/><br/>
      <b>3. Personalized History</b><br/>
      A comprehensive log for tracking and managing previous blood pressure and heart rate measurements over time.
    </td>
    <td>
      <img src="screenshots/ui_bot.png" width="300px" alt="AI-Powered Health Bot"/><br/>
      <b>4. AI Health Assistant</b><br/>
      Engage with an AI bot that analyzes your historical data and provides context-aware health recommendations.
    </td>
  </tr>
</table>

### 🧠 Technical Insight: Peak Detection Algorithm
A critical component of this project is the **Peak Detection Algorithm**. By analyzing the raw PPG signal (visible in screenshot 2), the algorithm identifies **systolic peaks**. The precise time interval between these peaks (the **RR-interval**) is then used to calculate the instantaneous Heart Rate (BPM), a foundational skill for further AI/ML applications in healthcare.



---
*Graduation Thesis - Electronics & IoT - Industrial University of Ho Chi Minh City (IUH)*
