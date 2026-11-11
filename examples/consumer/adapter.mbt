///|
/// Use a bbox bottom-center only when it represents the object's ground contact.
/// Callers may supply independently measured contact points instead. The pixel
/// standard deviation is configured measurement noise, not detector confidence.
pub fn tracker_observations(
  frame : @mbmot.FrameTracks,
  pixel_std : Double,
) -> Array[@moonground.PixelObservation] raise @moonground.GroundError {
  let covariance = @moonground.Covariance2::isotropic(pixel_std)
  frame
  .tracks()
  .map(track => {
    let bbox = track.bbox()
    @moonground.PixelObservation::new(
      track.track_id(),
      @moonground.Point2::new(
        bbox.x1() + (bbox.x2() - bbox.x1()) * 0.5,
        bbox.y2(),
      ),
      covariance,
    )
  })
}
