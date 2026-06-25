//
//  StationMediaPorts.swift
//  StudyCast
//
//  Fixed local RTP ports used between one hidden UxPlay helper and StudyCast.
//

import Foundation

struct StationMediaPorts {
    let videoRTP: Int
    let audioRTP: Int

    init(stationIndex: Int) {
        videoRTP = 36000 + stationIndex * 20
        audioRTP = videoRTP + 2
    }
}
